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
    /// 转写完成后回传一份，让详情页立刻用它切分段。
    var onDone: (LocalTranscript) -> Void = { _ in }

    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var downloads: DownloadStore
    @EnvironmentObject private var logs: LogStore
    @Environment(\.dismiss) private var dismiss

    @State private var stage: Stage = .checking
    @State private var transcriber = OnDeviceTranscriber()
    @State private var fetcher = FileDownloader()

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
    }

    init(item: Item, preview: Stage? = nil, onDone: @escaping (LocalTranscript) -> Void = { _ in }) {
        self.item = item
        self.preview = preview
        self.onDone = onDone
        _stage = State(initialValue: preview ?? .checking)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            ScrollView {
                VStack(alignment: .leading, spacing: Metric.space4) {
                    intro
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
            if preview == nil { await start() }
        }
    }

    // MARK: - 头尾

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 3) {
                Text("本机转写")
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
        Text("这条内容没有字幕。这里用系统听写把音轨转成文字，再交给 AI 切段落。"
             + "整个过程在本机完成，音频不会上传。")
            .font(.cnChip)
            .foregroundStyle(Color.cnInk2)
            .lineSpacing(5)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var privacyNote: some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "lock")
                .font(.system(size: 10, weight: .semibold))
                .padding(.top, 1)
            Text("转写出的文字会存在本机，下次进这条不用再跑一次。")
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
                Text("正在检查本机识别能力…")
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
                    Text("正在本机识别 · 已认出 \(chars) 字")
                        .font(.cnChip)
                        .foregroundStyle(Color.cnInk2)
                    Spacer(minLength: 0)
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

                Text("这一步没有总进度：系统只回文字，不回百分比。长片子按 1:8 左右估时间。")
                    .font(.cnMeta)
                    .foregroundStyle(Color.cnInk3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(Metric.space4)
            .background(cardBackground)

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
    private func start(force: Bool = false) async {
        stage = .checking

        // 已经转写过就直接给结果：一次转写几十秒到几分钟，
        // 用户可能只是关掉又点回来，没理由让他再等一遍。
        // `force` 是「重新转写」按钮走的路。
        if !force, let existing = LocalTranscriptStore.shared.load(id: item.id),
           !existing.lines.isEmpty {
            stage = .done(existing)
            return
        }

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

        do {
            let source = try await mediaFile()
            // 只登记、不直接删：用户已下载的那份在 Documents 里，
            // 由 `removeIfScratch` 的前缀判断挡掉。
            scratch.append(source)
            stage = .preparing("正在分离音轨…")
            let audio = try await AudioExtractor.extractM4A(from: source)
            scratch.append(audio.url)

            stage = .transcribing(tail: "", chars: 0)
            let started = Date()
            let transcript = try await transcriber.transcribe(
                file: audio.url,
                durationSeconds: audio.durationSeconds,
                itemId: item.id
            ) { tail, chars in
                Task { @MainActor in
                    if case .transcribing = stage {
                        stage = .transcribing(tail: tail, chars: chars)
                    }
                }
            }
            // m4a 与临时 mp4 都在函数出口由上面的 defer 清掉。

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
            stage = .failed(failure.errorDescription ?? "转写失败。")
            logs.error("transcribe.failed", failure.errorDescription ?? "转写失败", meta: [
                "id": item.id,
            ])
        } catch let failure as ClipNoteClient.Failure {
            stage = .failed(failure.displayMessage)
        } catch {
            stage = .failed(error.localizedDescription)
        }
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
        return try await download(url)
    }

    @MainActor
    private func download(_ url: URL) async throws -> URL {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<URL, Error>) in
            fetcher.download(from: url) { value in
                Task { @MainActor in
                    if case .preparing = stage {
                        stage = .preparing("正在取音源 · \(Int(value * 100))%")
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
