import AVFoundation
import Foundation
import Speech

/// 一条「本机转写」的文字行。
///
/// 和 `APITranscriptLine` 字段一样，但那个类型只实现了解码——它是服务端契约，
/// 不该为了本地缓存去改。本地这份要能编码，所以单独定义。
struct TranscriptLine: Codable, Equatable {
    var t: Int
    var text: String
}

/// 本机转写的结果。落盘在 Documents/local-transcripts，按条目 id 归位。
struct LocalTranscript: Codable, Equatable {
    var itemId: String
    var lines: [TranscriptLine]
    var durationSeconds: Int
    var createdAt: Date
    var locale: String

    /// 喂给 `Segmenter` 时用的形态：和从服务端拿字幕时完全一致，
    /// 于是切分段那条链路一行都不用改。
    var apiLines: [APITranscriptLine] {
        lines.map { APITranscriptLine(t: $0.t, text: $0.text) }
    }

    var lastT: Int { lines.last?.t ?? 0 }

    var charCount: Int { lines.reduce(0) { $0 + $1.text.count } }

    /// 转写覆盖到总时长的比例。低于 0.8 说明尾段没人声或识别中断，
    /// 界面要如实写出来——否则用户会以为「这条视频只有 3 分钟」。
    var coverage: Double {
        guard durationSeconds > 0 else { return 0 }
        return min(1, Double(lastT) / Double(durationSeconds))
    }
}

/// 本机转写的落盘。
///
/// 为什么不塞进 `LibraryStore` 的模型里：转写是**本机产物**，服务端不知道它的存在，
/// 下次同步一旦用服务端那份覆盖快照，文字就没了。放独立目录，按 id 取，
/// 服务端怎么变都不影响它。
final class LocalTranscriptStore {
    static let shared = LocalTranscriptStore()

    private let directory: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    /// `directory` 只给测试与截图用：传进来的目录里会再建一层 `local-transcripts`。
    init(directory: URL? = nil) {
        let fm = FileManager.default
        let base = directory ?? fm.urls(for: .documentDirectory, in: .userDomainMask).first!
        let folder = base.appendingPathComponent("local-transcripts", isDirectory: true)
        try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
        self.directory = folder

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        self.encoder = encoder

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.decoder = decoder
    }

    /// 条目 id 可能带路径字符，文件名必须清洗。复用下载那套规则，
    /// 免得同一个 id 在两处得到两个不同的文件名。
    func url(for id: String) -> URL {
        directory.appendingPathComponent("\(DownloadStore.fileStem(id)).json")
    }

    func load(id: String) -> LocalTranscript? {
        guard let data = try? Data(contentsOf: url(for: id)) else { return nil }
        return try? decoder.decode(LocalTranscript.self, from: data)
    }

    func has(id: String) -> Bool {
        FileManager.default.fileExists(atPath: url(for: id).path)
    }

    func save(_ transcript: LocalTranscript) {
        guard let data = try? encoder.encode(transcript) else { return }
        try? data.write(to: url(for: transcript.itemId), options: .atomic)
    }

    func remove(id: String) {
        try? FileManager.default.removeItem(at: url(for: id))
    }
}

// MARK: - 识别结果的整理（纯函数，可测）

/// 系统听写给的一小段（一个词或一个字）。时间戳是相对音频开头的秒数。
struct SpeechChunk: Equatable {
    var t: Double
    var duration: Double
    var text: String
}

/// 把「词」拼成「行」。
///
/// 为什么必须做这一步：`SFSpeechTranscription.segments` 是按词切的，
/// 一条 10 分钟的视频能出两三千段。直接喂给模型，token 全花在重复的
/// 时间戳上；而按行聚合后是几百行，正好对得上服务端字幕的粒度。
///
/// 断行规则三条，都是为了「一行念完是一句话」：
/// 1. 停顿超过 0.9 秒 —— 说话人自己换气了
/// 2. 已经攒到 46 个字 —— 再攒下去一行在界面上要折三折
/// 3. 上一段以句末标点结尾 —— 系统听写加了标点时，这是最准的信号
enum SpeechLineBuilder {
    static let maxGap: Double = 0.9
    static let maxChars: Int = 46
    /// 短于 3 个字的碎片多半是「嗯」「对」「啊」，留着只会给模型添噪
    static let minChars: Int = 3

    static func lines(from chunks: [SpeechChunk]) -> [TranscriptLine] {
        var out: [TranscriptLine] = []
        var buffer = ""
        var start: Double = 0
        var lastEnd: Double = 0

        func flush() {
            let text = tidy(buffer)
            buffer = ""
            guard !text.isEmpty else { return }
            var t = max(0, Int(start.rounded(.down)))
            // 时间必须严格递增：`APISegment.t` 用来跳转和排序，
            // 两行同一秒会让「跳到第 3 分钟」落在两段之间，说不清是哪一段。
            if let previous = out.last { t = max(t, previous.t + 1) }
            out.append(TranscriptLine(t: t, text: text))
        }

        for chunk in chunks {
            let piece = tidy(chunk.text)
            guard !piece.isEmpty else { continue }

            if !buffer.isEmpty {
                let gap = chunk.t - lastEnd
                if gap > maxGap || buffer.count + piece.count > maxChars || endsSentence(buffer) {
                    flush()
                }
            }
            if buffer.isEmpty { start = chunk.t }
            buffer = glue(buffer, piece)
            lastEnd = chunk.t + max(0, chunk.duration)
        }
        flush()

        let kept = out.filter { $0.text.count >= minChars }
        // 整条只有语气词时不能返回空——那会让上层误判成「转写失败」
        return kept.isEmpty ? out : kept
    }

    private static let sentenceEnd: Set<Character> = [
        "。", "！", "？", "；", "…", "!", "?", ";",
    ]

    private static func endsSentence(_ text: String) -> Bool {
        guard let last = text.last else { return false }
        return sentenceEnd.contains(last)
    }

    /// 中文直接连；两侧都是英数才补一个空格，否则「machinelearning」这种会粘成一坨。
    private static func glue(_ left: String, _ right: String) -> String {
        guard let a = left.last, let b = right.first else { return left + right }
        if a.isASCII, b.isASCII, a.isLetter || a.isNumber, b.isLetter || b.isNumber {
            return left + " " + right
        }
        return left + right
    }

    private static func tidy(_ raw: String) -> String {
        var text = raw.replacingOccurrences(of: "\n", with: " ")
        text = text.replacingOccurrences(of: "\t", with: " ")
        while text.contains("  ") {
            text = text.replacingOccurrences(of: "  ", with: " ")
        }
        return text.trimmingCharacters(in: .whitespaces)
    }
}

// MARK: - 能不能在本机跑

enum TranscribeSupport: Equatable {
    case ready
    /// 引擎在，但这台设备还没准备好在**本机**跑中文识别
    case needsAssets
    case unavailable(String)

    var message: String {
        switch self {
        case .ready:
            return "本机识别可用。音频不离开这台设备。"
        case .needsAssets:
            return "这台设备还不能在本机跑中文识别。多半是系统里没下载中文听写包——"
                + "设置 › 通用 › 键盘 › 听写语言 里加上「中文（普通话）」后回来再试。"
                + "模拟器不支持本机识别，属正常。"
        case .unavailable(let reason):
            return reason
        }
    }
}

/// 判定拆成纯函数，好让四条分支都能被单测覆盖——
/// `supportsOnDeviceRecognition` 在模拟器上永远给 false，真机走哪条分支
/// 本地根本验不了，只能靠这里保证逻辑本身是对的。
enum TranscribeGate {
    static func support(hasRecognizer: Bool, onDevice: Bool) -> TranscribeSupport {
        guard hasRecognizer else {
            return .unavailable("这个系统里没有中文听写引擎。需要 iOS 16 以上，并在键盘设置里打开听写。")
        }
        guard onDevice else { return .needsAssets }
        return .ready
    }
}

// MARK: - 「一直转圈」的兜底

/// 转写跑到哪一步。
///
/// 两步的「多久没动静算卡住」不一样，因为它们的进展信号不同：
/// 取音源 / 分离音轨有百分比，只要在下载就一定会动；转写阶段只有字数，
/// 而系统听写在一句话中间可以几十秒不吐新字，所以阈值必须放宽一些，
/// 否则会把正常的长句停顿误判成卡死。
enum TranscribePhase: Equatable {
    case preparing
    case transcribing

    var stallSeconds: Int {
        switch self {
        case .preparing:
            // 129MB 的包在 4G 下也要几分钟，但有百分比就不会误伤；
            // 这里卡的是「一个字节都没动」的情况。
            return 120
        case .transcribing:
            return 45
        }
    }
}

/// 把「无声的转圈」变成一句人话。
///
/// 为什么需要它：`SFSpeechRecognitionTask` 在真机上有一种失败是不回调的——
/// 既不 error 也不 final，界面就永远停在「正在本机识别 · 已认出 0 字」。
/// 用户看到的是一个转不完的圈，比一句明确的「停住了」糟糕得多。
/// 这里只做纯计算，判定与文案都能被单测钉住。
enum TranscribeWatchdog {
    /// 硬顶：一条 17 分钟的视频在本机转写约 3–5 分钟，45 分钟还没完
    /// 一定是出事了，继续等只是浪费电。
    static let hardLimitSeconds = 45 * 60

    static func isStalled(phase: TranscribePhase, secondsSinceProgress: Int) -> Bool {
        secondsSinceProgress >= phase.stallSeconds
    }

    static func isOverLimit(elapsed: Int) -> Bool {
        elapsed >= hardLimitSeconds
    }

    /// 说清三件事：停在哪一步、为什么可能停、现在该怎么办。
    static func message(phase: TranscribePhase, hardLimit: Bool = false) -> String {
        if hardLimit {
            return "已经跑了 45 分钟还没结束，这条多半超出本机能处理的范围了。"
                + "建议先换一条十几分钟的片子确认设备正常，长片再单独排查。"
        }
        switch phase {
        case .preparing:
            return "取音源这一步停了。多半是网络断了，或者平台给的地址已经过期——"
                + "重试会重新解析一次地址；连不上网时换 Wi-Fi 再试。"
        case .transcribing:
            return "系统听写这边停了。它在后台被系统回收、或听写服务短暂不可用时都会这样，"
                + "重试一次通常能接着跑；如果每次都停在同一处，先用一条短片子确认设备本身没问题。"
        }
    }
}

/// 底层错误 → 中文一句话。
///
/// 走的是 `localizedDescription` 之外的那条路：URLSession 与文件系统给的原文
/// 是英文（"The request timed out."），直接摆在界面上等于没说。
/// 认不出来的再退回原文，但补一句「可以怎么办」，不留一句孤零零的报错。
enum TranscribeMessage {
    static func humanize(_ error: Error) -> String {
        let ns = error as NSError
        if ns.domain == NSURLErrorDomain {
            switch ns.code {
            case NSURLErrorTimedOut:
                return "请求超时了。网络慢或平台没响应，重试一次；还超时就换个网络。"
            case NSURLErrorNotConnectedToInternet, NSURLErrorNetworkConnectionLost:
                return "网络断了。连上网再重试——已经转好的文字不会丢。"
            case NSURLErrorCannotFindHost, NSURLErrorCannotConnectToHost:
                return "连不上服务器。检查一下网络，或者稍后再试。"
            default:
                return "网络出错（\(ns.code)）。重试一次；还不行就把这串码发我。"
            }
        }
        if ns.domain == NSPOSIXErrorDomain, ns.code == Int(POSIXErrorCode.ENOSPC.rawValue) {
            return "本机存储满了。删掉几条已下载的内容腾出空间再试。"
        }
        if ns.domain == NSPOSIXErrorDomain {
            return "本机读写出错（\(ns.code)）。重启 App 再试一次。"
        }
        return "转写中断了：\(ns.localizedDescription)　重试一次；每次都这样就把这句发我。"
    }
}

enum OnDeviceSpeech {
    static let locale = Locale(identifier: "zh-CN")

    static func support() -> TranscribeSupport {
        guard let recognizer = SFSpeechRecognizer(locale: locale) else {
            return TranscribeGate.support(hasRecognizer: false, onDevice: false)
        }
        return TranscribeGate.support(hasRecognizer: true, onDevice: recognizer.supportsOnDeviceRecognition)
    }

    static var authorization: SFSpeechRecognizerAuthorizationStatus {
        SFSpeechRecognizer.authorizationStatus()
    }

    static func requestAuthorization() async -> SFSpeechRecognizerAuthorizationStatus {
        await withCheckedContinuation { (continuation: CheckedContinuation<SFSpeechRecognizerAuthorizationStatus, Never>) in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status)
            }
        }
    }
}

// MARK: - 转写引擎

/// 一次性的本机转写。
///
/// 两个刻意的选择：
/// - `requiresOnDeviceRecognition = true`。不设它，系统在断网时会**偷偷**把
///   音频传到 Apple 服务器；用户点的是「本机转写」，那就必须真的在本机。
/// - 只认 `isFinal`。部分结果每 100 毫秒变一次，攒进去会把同一句话重复几遍。
final class OnDeviceTranscriber {
    enum Failure: LocalizedError, Equatable {
        case notAuthorized
        case unsupported(String)
        case unreadable(String)
        case cancelled
        case empty
        case speech(String)

        var errorDescription: String? {
            switch self {
            case .notAuthorized:
                return "没有语音识别权限。到 设置 › 片记 › 语音识别 里打开后再试。"
            case .unsupported(let message):
                return message
            case .unreadable(let message):
                return message
            case .cancelled:
                return "已取消。"
            case .empty:
                return "识别完了但没有文字。可能是纯音乐、人声太轻，或者音轨是空的。"
            case .speech(let message):
                return message
            }
        }
    }

    private var task: SFSpeechRecognitionTask?
    /// 请求必须活到任务结束。Apple 的示例都把它放成属性；
    /// 交给局部变量的话，ARC 有可能在任务跑完之前就收走它。
    private var request: SFSpeechURLRecognitionRequest?

    /// 取消后系统会走一次 error 回调，那条路径上必须还能正常 resume，
    /// 所以这里不主动断，交给 `Once` 兜住重复 resume。
    func cancel() {
        task?.cancel()
    }

    /// `onProgress` 回传（尾部文字，已识别字数）。参数顺序刻意反过来：
    /// 界面上要显示的是字数，文字只是让人知道「它确实在动」。
    func transcribe(
        file: URL,
        durationSeconds: Int,
        itemId: String,
        onProgress: @escaping (String, Int) -> Void
    ) async throws -> LocalTranscript {
        guard SFSpeechRecognizer.authorizationStatus() == .authorized else {
            throw Failure.notAuthorized
        }
        guard let recognizer = SFSpeechRecognizer(locale: OnDeviceSpeech.locale) else {
            throw Failure.unsupported("这个系统里没有中文听写引擎。")
        }

        let request = SFSpeechURLRecognitionRequest(url: file)
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = true
        request.taskHint = .dictation
        request.addsPunctuation = true
        self.request = request

        let chunks: [SpeechChunk] = try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<[SpeechChunk], Error>) in
            let once = Once(continuation)
            self.task = recognizer.recognitionTask(with: request) { result, error in
                if let result {
                    if result.isFinal {
                        let mapped = result.bestTranscription.segments.map {
                            SpeechChunk(t: $0.timestamp, duration: $0.duration, text: $0.substring)
                        }
                        once.finish(.success(mapped))
                    } else {
                        let text = result.bestTranscription.formattedString
                        onProgress(String(text.suffix(40)), text.count)
                    }
                }
                if let error {
                    once.finish(.failure(Self.failure(from: error)))
                }
            }
        }

        task = nil
        self.request = nil
        let lines = SpeechLineBuilder.lines(from: chunks)
        guard !lines.isEmpty else { throw Failure.empty }

        // 系统不给总时长，所以由调用方从 AVAsset 里取；拿不到就按最后一段推。
        var duration = durationSeconds
        if duration <= 0, let last = chunks.last {
            duration = Int((last.t + last.duration).rounded())
        }
        return LocalTranscript(
            itemId: itemId,
            lines: lines,
            durationSeconds: max(0, duration),
            createdAt: Date(),
            locale: "zh-CN"
        )
    }

    private static func failure(from error: Error) -> Error {
        let ns = error as NSError
        if ns.domain == "kAFAssistantErrorDomain" {
            switch ns.code {
            // 216：任务被取消；1110：没有可用的音频。都当「用户取消」处理，
            // 不然界面上会冒出一条看不懂的英文错误。
            case 216, 1110:
                return Failure.cancelled
            case 203:
                return Failure.speech("系统听写这次没听懂。重试一次通常就好。")
            default:
                return Failure.speech("识别中断（\(ns.code)）。\(ns.localizedDescription)")
            }
        }
        return Failure.speech(ns.localizedDescription)
    }
}

/// 保证 continuation 只 resume 一次。
///
/// Speech 的回调会先给一次 error、再给一次 final result（或反之），
/// 直接 resume 必然崩在 "SWIFT TASK CONTINUATION MISUSE"。
private final class Once {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<[SpeechChunk], Error>?

    init(_ continuation: CheckedContinuation<[SpeechChunk], Error>) {
        self.continuation = continuation
    }

    func finish(_ result: Result<[SpeechChunk], Error>) {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        guard let pending else { return }
        pending.resume(with: result)
    }
}

// MARK: - 临时文件清理

/// 转写中间产物的删除规则。
///
/// 为什么需要一个判断而不是直接 `removeItem`：`mediaFile()` 有两条来源——
/// 用户已经下载到 Documents 的那份（这是用户数据，绝不能删）和这次为转写
/// 临时下到 tmp 的 mp4（必须删）。URL 在流程里来回流转时没有携带来源标记，
/// 路径前缀是唯一稳定的事实。
///
/// 要求落在目录**之内**而不是简单的 `hasPrefix`：否则 `/tmp` 与 `/tmp2`
/// 会被判成同一层，删错东西。这条规则本身是纯函数，好让单测把边界钉住。
enum TranscribeCleanup {
    static func isScratch(_ file: URL, temporaryDirectory: URL) -> Bool {
        let base = temporaryDirectory.standardizedFileURL.path
        let target = file.standardizedFileURL.path
        guard !base.isEmpty, target.hasPrefix(base) else { return false }
        let rest = target.dropFirst(base.count)
        return rest.hasPrefix("/") && rest.count > 1
    }

    /// 只删临时文件，用户已下载的文件会被静默放过。
    static func removeIfScratch(
        _ file: URL,
        temporaryDirectory: URL = FileManager.default.temporaryDirectory
    ) {
        guard isScratch(file, temporaryDirectory: temporaryDirectory) else { return }
        try? FileManager.default.removeItem(at: file)
    }
}

// MARK: - 取音轨

/// 从视频里抽出音轨。
///
/// 为什么不直接把 mp4 交给 `SFSpeechURLRecognitionRequest`：它对容器很挑，
/// mp4 里的音频能不能被读要看编码，而 m4a 是系统听写唯一保证能吃的形态。
/// 导出是本地解码再编码，一秒几倍速，10 分钟的视频约 2 秒。
enum AudioExtractor {
    static func extractM4A(from source: URL) async throws -> (url: URL, durationSeconds: Int) {
        let asset = AVURLAsset(url: source)
        // 同步取时长而不是 `load(.duration)`：这里一定是本地文件（刚下完或已下载），
        // 没有「网络资源要等」的问题，而同步那条路在 iOS 16 上行为最确定。
        var duration: Double = 0
        let time = asset.duration
        if time.isValid, !time.isIndefinite {
            duration = CMTimeGetSeconds(time)
        }

        guard let session = AVAssetExportSession(
            asset: asset,
            presetName: AVAssetExportPresetAppleM4A
        ) else {
            throw OnDeviceTranscriber.Failure.unreadable("这段内容里没有可用的音轨，没法转写。")
        }

        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent("cn-audio-\(UUID().uuidString).m4a")
        try? FileManager.default.removeItem(at: output)
        session.outputURL = output
        session.outputFileType = .m4a

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            session.exportAsynchronously { continuation.resume() }
        }

        guard session.status == .completed else {
            let reason = session.error?.localizedDescription ?? "音轨导出失败。"
            throw OnDeviceTranscriber.Failure.unreadable("取不到音轨：\(reason)")
        }
        return (output, max(0, Int(duration.rounded())))
    }
}
