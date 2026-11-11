import SwiftUI
import UIKit

/// 「本机转写」面板。
///
/// 存在的场景很具体：抖音 / 小红书的条目服务端拿不到字幕，于是分段那一步永远是
/// 「这条没有可用字幕」。而它们的音轨其实就在视频里——丢给系统听写就能出文字，
/// 不上传、不花钱、不用等服务器。这里把这条链路做成一个能看见进度的面板。
///
/// 为什么是独立面板而不是详情页里的一行进度：一次转写要几十秒到几分钟，
/// 期间用户需要知道「在跑」「跑到哪」「卡住了为什么」。挤在一行里只能写「处理中」，
/// 而失败时那行字会静悄悄消失——这是这个项目里已经踩过的坑。
struct TranscribeSheet: View {
    var item: Item
    /// 截图与预览专用：直接停在某一态，不真的跑转写。
    /// 正常路径传 nil，由 `start()` 走到对应状态。
    var preview: Stage?
    /// 预览态的计时。传 0 时计时不会显示（真跑的第一秒就是这样），
    /// 截图要证明「时间在走」就得给一个非零值。
    var previewElapsed: Int = 0
    /// 转写完成后回传一份，让详情页立刻用它切分段。
    var onDone: (LocalTranscript) -> Void = { _ in }

    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var downloads: DownloadStore
    @EnvironmentObject private var logs: LogStore
    @Environment(\.dismiss) private var dismiss

    @State private var stage: Stage = .checking
    @State private var transcriber = OnDeviceTranscriber()
    @State private var fetcher = FileDownloader()
    /// 已跑了多少秒。转写没有百分比，界面能给的唯一诚实信息就是时间。
    @State private var elapsed = 0
    /// 上一次「有动静」的时刻：下载百分比变了、或认出了新字。
    /// 看门狗看的是它与现在的差，不是总时长——慢和卡是两件事。
    @State private var lastProgress = Date()
    /// 每秒跳一次的看守。失去焦点就停，免得后台空转。
    @State private var monitor: Task<Void, Never>?

    /// 转写引擎与模型。放在 AppStorage：用户选过一次就别每回都问。
    @AppStorage("clipnote.transcribeEngine") private var enginePreference = TranscribeEngine.auto.rawValue
    @AppStorage("clipnote.transcribeModel") private var transcribeModelOverride = ""
    @State private var aiConfig = AIConfigStore.load()
    /// 这次实际跑的引擎。和偏好分开：偏好是「我想用哪个」，这里是「这次真用了哪个」。
    @State private var runningEngine: TranscribeEngine = .onDevice
    /// 云端的分段进度，例如「第 3/30 段」。
    @State private var progressNote = ""

    private var cloudConfig: CloudASRConfig {
        let model = TranscribeModel.resolve(base: aiConfig.base, override: transcribeModelOverride)
        return CloudASRConfig(base: aiConfig.base, key: aiConfig.key, model: model)
    }

    private var enginePreferenceValue: TranscribeEngine {
        TranscribeEngine(rawValue: enginePreference) ?? .auto
    }

    private var engineLabel: String {
        activeEngine == .cloud ? "云端" : "本机"
    }

    /// 界面上该显示哪个引擎。
    ///
    /// 还没开跑时（`.checking`）用偏好算出来的那个，否则第一帧会闪一下「本机」，
    /// 紧跟着又变成「云端」——看起来像点错了。
    private var activeEngine: TranscribeEngine {
        if case .checking = stage {
            return TranscribeEngineDecision.resolve(
                preference: enginePreferenceValue,
                cloudReady: cloudConfig.isReady
            )
        }
        return runningEngine
    }

    enum Stage: Equatable {
        case checking
        /// 本机跑不了，或某一步明确不成立。文案里写清楚「为什么」和「怎么办」。
        case blocked(String)
        /// 系统权限没给。这一态只有跳设置能解，重试没用。
        case needsPermission
        case preparing(String)
        case transcribing(tail: String, chars: Int)
        case done(LocalTranscript)
        case failed(String)
        /// 长时间没有任何进展。和 `failed` 分开，是因为它可能只是系统把任务
        /// 丢了，重试多半能接着跑——文案和按钮都不一样。
        /// 带上停在哪一步：取音源停和识别停，原因和办法不是一回事。
        case stalled(seconds: Int, phase: TranscribePhase)
    }

    init(
        item: Item,
        preview: Stage? = nil,
        previewElapsed: Int = 0,
        /// 只给截图用：模拟器上没有 Keychain 配置，云端永远「未配置」，
        /// 那张「云端转写中」的图就拍不出来。真机路径不经过这个参数。
        previewEngine: TranscribeEngine? = nil,
        onDone: @escaping (LocalTranscript) -> Void = { _ in }
    ) {
        self.item = item
        self.preview = preview
        self.onDone = onDone
        _stage = State(initialValue: preview ?? .checking)
        _elapsed = State(initialValue: previewElapsed)
        _runningEngine = State(initialValue: previewEngine ?? .onDevice)
        if previewEngine == .cloud {
            // 截图要给真实形态：云端的进度就是「第 n/N 段」。
            _progressNote = State(initialValue: "云端转写 · 第 3/30 段")
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            ScrollView {
                VStack(alignment: .leading, spacing: Metric.space4) {
                    intro
                    engineRow
                    stageBlock
                    privacyNote
                }
                .padding(.horizontal, Metric.pagePad)
                .padding(.bottom, Metric.space5)
            }

            footer
        }
        .background(Color.cnBg)
        // 截图态不自动跑：`preview` 给的是终态，再跑一遍会把它盖掉。
        .task {
            aiConfig = AIConfigStore.load()
            if preview == nil { await start() }
        }
        // 面板关掉后看守没有意义，留着只是每秒醒一次。
        .onDisappear { stopMonitor() }
    }

    // MARK: - 头尾

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 3) {
                Text("转写")
                    .font(.cnTitle)
                    .foregroundStyle(Color.cnInk)
                Text(item.title)
                    .font(.cnMeta)
                    .foregroundStyle(Color.cnInk3)
                    .lineLimit(1)
            }
            Spacer(minLength: Metric.space3)
            Button {
                transcriber.cancel()
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.cnInk3)
                    .frame(width: 28, height: 28)
                    .background(Color.cnCard2, in: Circle())
            }
            .buttonStyle(PressDimStyle())
            .accessibilityLabel("关闭")
        }
        .padding(.horizontal, Metric.pagePad)
        .padding(.top, Metric.space5)
        .padding(.bottom, Metric.space4)
    }

    @ViewBuilder
    private var footer: some View {
        VStack(spacing: Metric.space2) {
            switch stage {
            case .done(let transcript):
                PrimaryButton(title: "用它切分段") {
                    onDone(transcript)
                    dismiss()
                }
                HStack(spacing: Metric.space3) {
                    Text("只发文字，不发音频。")
                        .font(.cnMeta)
                        .foregroundStyle(Color.cnInk3)
                    Spacer(minLength: 0)
                    Button("重新转写") {
                        Task { await start(force: true) }
                    }
                    .font(.cnMeta)
                    .foregroundStyle(Color.cnBrand)
                    .buttonStyle(.plain)
                }

            case .failed:
                PrimaryButton(title: "重试") {
                    Task { await start() }
                }
                // 转写失败最常见的原因就是「这条路不适合这条片子」：
                // 云端 401/限流，或本机太慢被判停住。给一条换路的出口，
                // 比让用户退出去找设置要直接。
                if cloudConfig.isReady {
                    Button(runningEngine == .cloud ? "改用本机转写" : "改用云端转写（更快更准）") {
                        Task { await switchEngine() }
                    }
                    .font(.cnChip)
                    .foregroundStyle(Color.cnInk3)
                    .buttonStyle(.plain)
                }

            case .stalled:
                // 停住时给两个出口：再跑一次（多数情况能接上），或者收工。
                // 不给「取消」——转写任务已经停了，留着这个词反而像还没停。
                PrimaryButton(title: "再跑一次") {
                    Task { await start() }
                }
                Button("先不转") { dismiss() }
                    .font(.cnChip)
                    .foregroundStyle(Color.cnInk3)
                    .buttonStyle(.plain)

            case .needsPermission:
                PrimaryButton(title: "去设置里打开") {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        UIApplication.shared.open(url)
                    }
                }

            case .transcribing, .preparing:
                Button("取消") {
                    transcriber.cancel()
                    dismiss()
                }
                .font(.cnChip)
                .foregroundStyle(Color.cnInk3)
                .buttonStyle(.plain)

            case .blocked:
                Button("知道了") { dismiss() }
                    .font(.cnChip)
                    .foregroundStyle(Color.cnInk3)
                    .buttonStyle(.plain)

            case .checking:
                EmptyView()
            }
        }
        .padding(.horizontal, Metric.pagePad)
        .padding(.bottom, Metric.space4)
        .padding(.top, Metric.space2)
    }

    // MARK: - 说明

    private var intro: some View {
        Text(activeEngine == .cloud
             ? "这条内容没有字幕。这里把音轨切成两分钟一段，交给转写模型出文字，再让 AI 切段落。"
             : "这条内容没有字幕。这里用系统听写把音轨转成文字，再交给 AI 切段落。整个过程在本机完成，音频不会上传。")
            .font(.cnChip)
            .foregroundStyle(Color.cnInk2)
            .lineSpacing(5)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// 引擎开关。
    ///
    /// 默认是云端：本机识别在长视频上慢到不能用，准确率也明显不如云端
    /// （用户原话）。但**必须留一个本机出口**——音频要不要离开设备，
    /// 是用户自己的决定，不该替他定死。
    private var engineRow: some View {
        HStack(spacing: Metric.space2) {
            Image(systemName: activeEngine == .cloud ? "cloud" : "iphone")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color.cnBrand)
            Text(activeEngine == .cloud ? "云端转写 · 更快更准" : "本机转写 · 音频不上传")
                .font(.cnMeta)
                .foregroundStyle(Color.cnInk2)
            Spacer(minLength: 0)
            // 条件是「云端可用」**或**「当前正跑在云端」：
            // 只看可用性的话，没配置时的云端预览态会既没有按钮也没有说明，
            // 看起来像坏了。
            if cloudConfig.isReady || activeEngine == .cloud {
                Button(activeEngine == .cloud ? "改用本机" : "改用云端") {
                    Task { await switchEngine() }
                }
                .font(.cnMeta)
                .foregroundStyle(Color.cnBrand)
                .buttonStyle(.plain)
            } else {
                Text("未配置模型，云端不可用")
                    .font(.cnMeta)
                    .foregroundStyle(Color.cnInk3)
            }
        }
    }

    /// 换引擎并立刻重跑。切换这件事本身说明用户想换结果，不该让他再点一次重试。
    private func switchEngine() async {
        let next: TranscribeEngine = runningEngine == .cloud ? .onDevice : .cloud
        enginePreference = next.rawValue
        progressNote = ""
        await start(force: true)
    }

    private var privacyNote: some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "lock")
                .font(.system(size: 10, weight: .semibold))
                .padding(.top, 1)
            Text(activeEngine == .cloud
                 ? "音频会分段发给你的模型服务；转写出的文字存在本机，下次进这条不用再跑一次。"
                 : "转写出的文字会存在本机，下次进这条不用再跑一次。")
                .font(.cnMeta)
                .fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(Color.cnInk3)
    }

    // MARK: - 状态区

    @ViewBuilder
    private var stageBlock: some View {
        switch stage {
        case .checking:
            HStack(spacing: Metric.space3) {
                ActivitySpinner(style: .medium)
                Text(activeEngine == .cloud ? "正在检查云端转写…" : "正在检查本机识别能力…")
                    .font(.cnChip)
                    .foregroundStyle(Color.cnInk3)
                Spacer(minLength: 0)
            }
            .padding(Metric.space4)
            .background(cardBackground)

        case .blocked(let message):
            noticeCard(
                icon: "exclamationmark.circle",
                title: "这台设备暂时不行",
                detail: message,
                tint: Color.cnInk2
            )

        case .needsPermission:
            noticeCard(
                icon: "mic.slash",
                title: "还没给语音识别权限",
                detail: "系统需要你允许一次，才能在本机读音频。允许之后音频仍然不出设备。",
                tint: Color.cnInk2
            )

        case .preparing(let message):
            VStack(alignment: .leading, spacing: Metric.space3) {
                HStack(spacing: Metric.space3) {
                    ActivitySpinner(style: .medium)
                    Text(message)
                        .font(.cnChip)
                        .foregroundStyle(Color.cnInk2)
                    Spacer(minLength: 0)
                    // 时间在动，就说明没死。这是「转圈」唯一缺的那条证据。
                    if elapsed > 0 {
                        Text(Self.mmss(elapsed))
                            .font(.cnDuration)
                            .foregroundStyle(Color.cnInk3)
                            .monospacedDigit()
                    }
                }
                Text("第一次要先把音轨取下来。已下载到本地的条目会跳过这一步。")
                    .font(.cnMeta)
                    .foregroundStyle(Color.cnInk3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(Metric.space4)
            .background(cardBackground)

        case .transcribing(let tail, let chars):
            VStack(alignment: .leading, spacing: Metric.space3) {
                HStack(spacing: Metric.space3) {
                    ActivitySpinner(style: .medium)
                    Text(progressNote.isEmpty
                         ? "正在\(engineLabel)识别 · 已认出 \(chars) 字"
                         : "\(progressNote) · 已认出 \(chars) 字")
                        .font(.cnChip)
                        .foregroundStyle(Color.cnInk2)
                    Spacer(minLength: 0)
                    Text(Self.mmss(elapsed))
                        .font(.cnDuration)
                        .foregroundStyle(Color.cnInk3)
                        .monospacedDigit()
                }

                // 只显示尾巴：这是「它确实在动」的证据。
                // 显示整段会让面板在长时间转写里一直跳，反而不好读。
                if !tail.isEmpty {
                    Text(tail)
                        .font(.cnMeta)
                        .foregroundStyle(Color.cnInk3)
                        .lineLimit(3)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(Metric.space3)
                        .background(
                            Color.cnCard2,
                            in: RoundedRectangle(cornerRadius: Metric.radiusCover, style: .continuous)
                        )
                }

                Text(activeEngine == .cloud
                     ? "按 2 分钟一段上传，段数就是进度。1 小时的片子大约 30 段。"
                     : "这一步没有总进度：系统只回文字，不回百分比。长片子按 1:8 左右估时间。")
                    .font(.cnMeta)
                    .foregroundStyle(Color.cnInk3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(Metric.space4)
            .background(cardBackground)

        case .stalled(let seconds, let phase):
            // 硬顶和「卡住」共用一个状态：秒数本身说明了是哪一种，
            // 多存一个布尔值只会多一条能对不上的信息。
            noticeCard(
                icon: "hourglass",
                title: "跑到 \(Self.mmss(seconds)) 停住了",
                detail: TranscribeWatchdog.message(
                    phase: phase,
                    hardLimit: seconds >= TranscribeWatchdog.hardLimitSeconds
                ),
                tint: Color.cnInk2
            )

        case .done(let transcript):
            doneBlock(transcript)

        case .failed(let message):
            noticeCard(
                icon: "exclamationmark.triangle",
                title: "转写没走完",
                detail: message,
                tint: Color.cnRed
            )
        }
    }

    private func doneBlock(_ transcript: LocalTranscript) -> some View {
        VStack(alignment: .leading, spacing: Metric.space3) {
            HStack(spacing: 6) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 12, weight: .semibold))
                Text("转写完成 · \(transcript.lines.count) 行 · \(transcript.charCount) 字")
                    .font(.cnChip)
                Spacer(minLength: 0)
            }
            .foregroundStyle(Color.cnGreen)

            // 覆盖率：尾段没人声时系统会提前结束，不写出来用户会以为视频只有 3 分钟
            if transcript.coverage > 0, transcript.coverage < 0.8 {
                Text("只覆盖到 \(Self.mmss(transcript.lastT))，后面多半是没人声的片段。")
                    .font(.cnMeta)
                    .foregroundStyle(Color.cnInk3)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 0) {
                // 只列前 5 行：这里要证明的是「文字像样」，不是让人现场通读
                ForEach(Array(transcript.lines.prefix(5).enumerated()), id: \.offset) { index, line in
                    if index > 0 {
                        Rectangle()
                            .fill(Color.cnHairlineSoft)
                            .frame(height: 1)
                    }
                    HStack(alignment: .top, spacing: Metric.space2) {
                        Text(Self.mmss(line.t))
                            .font(.cnDuration)
                            .foregroundStyle(Color.cnInk3)
                            .frame(width: 36, alignment: .leading)
                        Text(line.text)
                            .font(.cnMeta)
                            .foregroundStyle(Color.cnInk2)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                    }
                    .padding(.vertical, 7)
                }
            }

            if transcript.lines.count > 5 {
                Text("还有 \(transcript.lines.count - 5) 行，切完分段就能按段落读。")
                    .font(.cnMeta)
                    .foregroundStyle(Color.cnInk3)
            }
        }
        .padding(Metric.space4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(cardBackground)
    }

    private func noticeCard(icon: String, title: String, detail: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: Metric.space2) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .semibold))
                Text(title)
                    .font(.cnChip)
                Spacer(minLength: 0)
            }
            .foregroundStyle(tint)

            Text(detail)
                .font(.cnMeta)
                .foregroundStyle(Color.cnInk3)
                .lineSpacing(4)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(Metric.space4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(cardBackground)
    }

    private var cardBackground: some View {
        RoundedRectangle(cornerRadius: Metric.radiusCard, style: .continuous)
            .fill(Color.cnCard)
            .overlay(
                RoundedRectangle(cornerRadius: Metric.radiusCard, style: .continuous)
                    .strokeBorder(Color.cnHairline, lineWidth: 1)
            )
    }

    static func mmss(_ seconds: Int) -> String {
        let value = max(0, seconds)
        return String(format: "%02d:%02d", value / 60, value % 60)
    }

    // MARK: - 流程

    @MainActor
    /// 云端转写。
    ///
    /// 进度按「段」而不是按百分比：段数就是真实的分母，而且每一段回来都是一次
    /// 确定的进展——比一个不知道怎么算出来的百分比可信。
    private func runCloud(audio: (url: URL, durationSeconds: Int), itemId: String) async throws -> LocalTranscript {
        guard audio.durationSeconds > 0 else {
            throw CloudASRError.badReply("取不到音频时长，没法切片")
        }
        stage = .transcribing(tail: "", chars: 0)
        progressNote = "云端转写 · 准备上传"
        lastProgress = Date()

        return try await CloudTranscriber().transcribe(
            audio: audio.url,
            durationSeconds: audio.durationSeconds,
            itemId: itemId,
            config: cloudConfig
        ) { done, total, chars in
            Task { @MainActor in
                progressNote = "云端转写 · 第 \(done)/\(total) 段"
                if case .transcribing = stage {
                    stage = .transcribing(tail: "", chars: chars)
                }
                lastProgress = Date()
            }
        }
    }

    private func start(force: Bool = false) async {
        stopMonitor()
        stage = .checking
        elapsed = 0
        lastProgress = Date()

        // 已经转写过就直接给结果：一次转写几十秒到几分钟，
        // 用户可能只是关掉又点回来，没理由让他再等一遍。
        // `force` 是「重新转写」按钮走的路。
        if !force, let existing = LocalTranscriptStore.shared.load(id: item.id),
           !existing.lines.isEmpty {
            stage = .done(existing)
            return
        }

        // 先定引擎。云端不碰系统听写，所以不该在云端路径上要语音识别权限——
        // 之前那条路必须先授权才能往下走，等于把一个「本机才需要」的门槛
        // 放在了所有人面前。
        let engine = TranscribeEngineDecision.resolve(
            preference: enginePreferenceValue,
            cloudReady: cloudConfig.isReady
        )
        runningEngine = engine
        progressNote = ""
        logs.info("transcribe.engine", "引擎：\(engine.title)", meta: [
            "id": item.id,
            "engine": engine.rawValue,
            "model": engine == .cloud ? cloudConfig.model : "-",
            "preference": enginePreferenceValue.rawValue,
        ])

        if engine == .onDevice {
            let support = OnDeviceSpeech.support()
            guard support == .ready else {
                stage = .blocked(support.message)
                logs.warn("transcribe.unsupported", "本机识别不可用", meta: ["id": item.id])
                return
            }

            var status = OnDeviceSpeech.authorization
            if status == .notDetermined {
                status = await OnDeviceSpeech.requestAuthorization()
            }
            guard status == .authorized else {
                stage = .needsPermission
                logs.warn("transcribe.denied", "语音识别权限未给", meta: ["id": item.id])
                return
            }
        }

        // 转写要在本地折腾两份文件：为取音源临时下的 mp4（抖音十来兆，B 站
        // 能到上百兆）和从里面抽出来的 m4a。两份都得清。
        // 用 defer 而不是在成功路径末尾删，是因为失败和取消也得清——之前只有
        // 成功时删了 m4a，下载的那份 mp4 从头到尾没删过，转几次大视频就白占
        // 几百兆，而 tmp 什么时候被系统回收没有保证。
        var scratch: [URL] = []
        defer {
            for file in scratch {
                TranscribeCleanup.removeIfScratch(file)
            }
        }
        // 看守从这里开始：下面每一步都可能静默停住，而界面上只有一个转圈。
        startMonitor()
        defer { stopMonitor() }

        do {
            let source = try await mediaFile()
            // 只登记、不直接删：用户已下载的那份在 Documents 里，
            // 由 `removeIfScratch` 的前缀判断挡掉。
            scratch.append(source)
            // 看守在取音源期间就可能判定停住。这里必须先退出，
            // 否则下载晚一步回来会把「停住了」那张卡又推走，用户看到界面自己跳回去。
            guard !isResolved else { return }
            stage = .preparing("正在分离音轨…")
            lastProgress = Date()
            let audio = try await AudioExtractor.extractM4A(from: source)
            scratch.append(audio.url)
            guard !isResolved else { return }

            stage = .transcribing(tail: "", chars: 0)
            lastProgress = Date()
            let started = Date()
            let transcript: LocalTranscript
            if engine == .cloud {
                transcript = try await runCloud(audio: audio, itemId: item.id)
            } else {
                transcript = try await transcriber.transcribe(
                    file: audio.url,
                    durationSeconds: audio.durationSeconds,
                    itemId: item.id
                ) { tail, chars in
                    Task { @MainActor in
                        if case .transcribing = stage {
                            stage = .transcribing(tail: tail, chars: chars)
                            lastProgress = Date()
                        }
                    }
                }
            }
            // m4a 与临时 mp4 都在函数出口由上面的 defer 清掉。
            guard !isResolved else { return }

            LocalTranscriptStore.shared.save(transcript)
            stage = .done(transcript)
            logs.info("transcribe.finished", "本机转写完成，\(transcript.lines.count) 行", meta: [
                "id": item.id,
                "lines": String(transcript.lines.count),
                "chars": String(transcript.charCount),
                "cover": String(format: "%.2f", transcript.coverage),
                "ms": String(Int(Date().timeIntervalSince(started) * 1000)),
            ])
        } catch let failure as OnDeviceTranscriber.Failure {
            // 看守判定停住后会主动 cancel，那条路径上系统必然回调一个
            // 「已取消」，不能让它把「卡住了」这张卡盖掉——真机上很难解释。
            guard !isResolved else { return }
            stage = .failed(failure.errorDescription ?? "转写失败。")
            logs.error("transcribe.failed", failure.errorDescription ?? "转写失败", meta: [
                "id": item.id,
            ])
        } catch let failure as CloudASRError {
            guard !isResolved else { return }
            stage = .failed(failure.errorDescription ?? "云端转写失败。")
            logs.error("transcribe.cloud_failed", failure.errorDescription ?? "云端转写失败", meta: [
                "id": item.id,
                "model": cloudConfig.model,
            ])
        } catch let failure as ClipNoteClient.Failure {
            guard !isResolved else { return }
            stage = .failed(failure.displayMessage)
        } catch {
            guard !isResolved else { return }
            stage = .failed(TranscribeMessage.humanize(error))
            logs.error("transcribe.failed", TranscribeMessage.humanize(error), meta: [
                "id": item.id,
            ])
        }
    }

    // MARK: - 看守

    /// 已经给出结论的状态。到这里就不再让晚到的回调改写界面。
    private var isResolved: Bool {
        switch stage {
        case .done, .stalled: return true
        default: return false
        }
    }

    private var runningPhase: TranscribePhase? {
        switch stage {
        // `.checking` 归到准备阶段：这一段在等 `playback` 接口回地址，
        // 断网时会静默等十几秒，正是最需要被看守的一段。
        case .checking, .preparing: return .preparing
        case .transcribing: return .transcribing
        default: return nil
        }
    }

    /// 每秒跳一次，只在 `preparing` / `transcribing` 两态里计数。
    ///
    /// 判定用的不是总时长而是「距上次有动静过了多久」：一条 40 分钟的片子
    /// 跑 6 分钟是正常的，一条 3 分钟的片子跑 6 分钟不是。
    private func startMonitor() {
        stopMonitor()
        monitor = Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                if Task.isCancelled { return }
                guard let phase = runningPhase else { return }
                elapsed += 1
                let idle = Int(Date().timeIntervalSince(lastProgress))

                if TranscribeWatchdog.isStalled(phase: phase, secondsSinceProgress: idle) {
                    stop(stalledAfter: elapsed, phase: phase)
                    return
                }
                if TranscribeWatchdog.isOverLimit(elapsed: elapsed) {
                    stop(stalledAfter: elapsed, phase: phase, hardLimit: true)
                    return
                }
            }
        }
    }

    private func stopMonitor() {
        monitor?.cancel()
        monitor = nil
    }

    private func stop(stalledAfter seconds: Int, phase: TranscribePhase, hardLimit: Bool = false) {
        // 先落状态再取消：取消会立刻回调一个 error，那条路径上 `isResolved`
        // 必须已经是 true，否则界面会被改写回「已取消」。
        stage = .stalled(seconds: seconds, phase: phase)
        monitor = nil
        transcriber.cancel()
        logs.warn("transcribe.stalled", "转写停住：\(phase)", meta: [
            "id": item.id,
            "sec": String(seconds),
            "hard": hardLimit ? "1" : "0",
        ])
    }

    /// 已下载的条目直接用本地文件：省一次下载，也避开地址过期。
    @MainActor
    private func mediaFile() async throws -> URL {
        if let local = downloads.localURL(for: item.id),
           FileManager.default.fileExists(atPath: local.path) {
            return local
        }
        guard item.playbackAvailable else {
            throw OnDeviceTranscriber.Failure.unreadable("这条内容没有视频流，没有可转写的音频。")
        }
        guard let payload = try await library.playback(for: item.id),
              let url = URL(string: payload.url) else {
            throw OnDeviceTranscriber.Failure.unreadable("取不到播放地址。地址过期时重进这一页会重新解析。")
        }

        stage = .preparing("正在取音源 · 0%")
        lastProgress = Date()
        return try await download(url)
    }

    @MainActor
    private func download(_ url: URL) async throws -> URL {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<URL, Error>) in
            fetcher.download(from: url) { value in
                Task { @MainActor in
                    if case .preparing = stage {
                        stage = .preparing("正在取音源 · \(Int(value * 100))%")
                        // 百分比每跳一次都算「有动静」：4G 下 129MB 要几分钟，
                        // 但只要在下载就不该被看门狗判成卡死。
                        lastProgress = Date()
                    }
                }
            } onFinish: { result in
                switch result {
                case .success(let file):
                    continuation.resume(returning: file)
                case .failure(let error):
                    continuation.resume(throwing: OnDeviceTranscriber.Failure.unreadable(
                        "音源下载失败：\(error.localizedDescription)"
                    ))
                }
            }
        }
    }
}
