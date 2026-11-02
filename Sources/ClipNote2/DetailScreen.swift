import AVKit
import SwiftUI

/// 详情页（画布 05 / 07 / 08）
///
/// 播放器先给封面 + 播放键，点了才创建 `AVPlayer`：
/// 一来首帧稳定（截图可比），二来避免未点播就占用解码资源。
///
/// 播放地址**不在模型里**：视频流地址几小时后会过期，快照里那份早就死了。
/// 所以进页面时异步取一次 `/api/v2/items/{id}/playback`（服务端会重新解析，
/// 约 1 秒），取回来后按钮下面就能写出「720P · 约 124 MB」——
/// 用户点「下载」之前有权知道自己要花多少流量。
struct DetailScreen: View {
    var item: Item

    /// 播放地址的准备状态。
    ///
    /// 单独一个状态机而不是一堆布尔：`isPreparing` + `error` + `url` 三个变量
    /// 能组合出 8 种状态，其中 5 种是矛盾的。
    enum PrepareState: Equatable {
        case idle
        case loading
        case ready(APIPlaybackPayload)
        /// 服务端 409：这类内容**永远**没有视频流（笔记、图集）
        case unavailable
        /// 服务端 501：有视频流，但这个平台这一版还没接解析。
        /// 和 `unavailable` 分开，是因为「暂时不行」不该说成「永远不行」，
        /// 也不该给一个点了也没用的重试引导。
        case unsupported(String)
        case failed(String)
    }

    @EnvironmentObject private var downloads: DownloadStore
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var logs: LogStore

    @State private var player: AVPlayer?
    @State private var playing = false
    @State private var showFullscreen = false
    @State private var showAISettings = false
    @State private var showSegments = false
    @State private var aiState: AIState = .idle
    @State private var segmentState: SegmentState = .idle
    @State private var notice: String?
    @State private var statusObservation: NSKeyValueObservation?
    @State private var prepare: PrepareState = .idle
    /// 进页面要不要自动总结。默认**不自动**：AI 是用户自己的额度，
    /// 只是路过看一眼不该先花一次调用。设置里可以改成自动。
    @AppStorage("clipnote.autoSummary") private var autoSummary = false

    /// `initialPrepare` 只给截图用：让「已取到地址」这一态可被拍下来。
    /// 正常路径一律 `.idle`，由 `prefetch()` 去取。
    init(item: Item, initialPrepare: PrepareState? = nil) {
        self.item = item
        if let initialPrepare {
            _prepare = State(initialValue: initialPrepare)
        }
    }

    /// 摘要这一块自己的状态。和播放地址的 `PrepareState` 分开：
    /// 一个是「能不能播」，一个是「有没有文稿」，混在一起会互相牵制。
    enum AIState: Equatable {
        case idle
        case running
        case needsSetup
        case failed(String)
    }

    /// 分段这一块的状态。和 `AIState` 分开：
    /// 摘要已经有了、分段却还没做，是很常见的一态，不能共用一个状态机。
    enum SegmentState: Equatable {
        case idle
        case running
        /// 服务端明确说了拿不到原料（没字幕 / 平台没接）。这不是失败，重试也没用。
        case blocked(String)
        case failed(String)
    }

    private var isPreparing: Bool { prepare == .loading }

    /// 简介太短就不整块渲染。
    ///
    /// 真实数据的 `desc` 常常只是「感谢索导的配音@索拉KG5TEP」——16 个字，
    /// 挂一个「简介」小标题去压一句致谢，比留白更难看。
    /// 20 这个阈值是产品判断，不是技术限制；要改就改这一处。
    private var showsSummary: Bool { item.summary.count >= 20 }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                playerSurface

                VStack(alignment: .leading, spacing: Metric.space3) {
                    Text(item.title)
                        .font(.cnTitle)
                        .foregroundStyle(Color.cnInk)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)

                    Text(metaLine)
                        .font(.cnMeta)
                        .foregroundStyle(Color.cnInk3)

                    aiSection

                    if showsSummary {
                        Rectangle()
                            .fill(Color.cnHairline)
                            .frame(height: 1)
                            .padding(.vertical, Metric.space1)

                        Text("简介")
                            .font(.cnCaption)
                            .foregroundStyle(Color.cnInk3)

                        Text(item.summary)
                            .font(.cnChip)
                            .foregroundStyle(Color.cnInk2)
                            .lineSpacing(6)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    if let notice {
                        Text(notice)
                            .font(.cnMeta)
                            .foregroundStyle(Color.cnRed)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    downloadSection
                        .padding(.top, Metric.space2)
                }
                .padding(Metric.pagePad)
            }
        }
        .background(Color.cnBg)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .tabBar)
        // 全屏入口只放在导航栏，不放播放器右下角：
        // 那块正是系统控制条的地盘，放上去要么互相遮挡，要么得写一套
        // 「控制条出现时隐藏我」的观察逻辑，而 VideoPlayer 不暴露这个状态。
        .toolbar {
            if playing {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        showFullscreen = true
                    } label: {
                        Image(systemName: "arrow.up.left.and.arrow.down.right")
                            .font(.system(size: 15, weight: .semibold))
                    }
                    .accessibilityLabel("全屏播放")
                }
            }
        }
        // 共用同一个 AVPlayer 实例：退出全屏后接着播，不重建、不重新拉流。
        .fullScreenCover(isPresented: $showFullscreen) {
            PlayerScreen(item: item, player: player)
        }
        // 进页面就先取一次地址：这样「下载到本地」旁边能标出体积，
        // 而不是让用户点下去才知道下多大。有 5 分钟缓存，来回切页不会重复打上游。
        .task {
            await prefetch()
            await maybeSummarize()
            await maybeLoadSegments()
        }
        .navigationDestination(isPresented: $showSegments) {
            SegmentsScreen(item: current)
        }
        .sheet(isPresented: $showAISettings) {
            NavigationStack { AISettingsScreen() }
        }
        .onChange(of: showAISettings) { presented in
            // 从设置页回来：之前因为没配置而停下的，重新试一次
            guard !presented, aiState == .needsSetup else { return }
            aiState = .idle
            Task { await maybeSummarize() }
        }
        // 单参数写法：iOS 16 没有「旧值、新值」那个双参数版本
        .onChange(of: downloads.lastFailure) { failure in
            guard let failure, failure.id == item.id else { return }
            notice = failure.message
        }
    }

    /// 服务端已经给好 `metaLine` 和 `durationText`，这里只负责摆位置。
    private var metaLine: String {
        item.durationText.isEmpty ? item.metaLine : "\(item.metaLine) · \(item.durationText)"
    }

    // MARK: - 播放器

    private var playerSurface: some View {
        // 用 Color.clear 撑出 16:9 再叠内容：直接给 ZStack 加 aspectRatio
        // 在高度不受约束的 ScrollView 里容易塌成 0。
        Color.clear
            .aspectRatio(16.0 / 9.0, contentMode: .fit)
            .overlay {
                if playing, let player {
                    VideoPlayer(player: player)
                } else {
                    ZStack {
                        LinearGradient(
                            colors: [item.coverTop, item.coverBottom],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )

                        if let url = item.coverURL {
                            AsyncImage(url: url, transaction: Transaction(animation: nil)) { phase in
                                if case .success(let image) = phase {
                                    image.resizable().scaledToFill()
                                }
                            }
                        }

                        if item.playbackAvailable {
                            playButton
                        } else {
                            noStreamBadge
                        }
                    }
                }
            }
            .clipped()
    }

    private var playButton: some View {
        Button {
            Task { await startPlayback() }
        } label: {
            ZStack {
                Circle()
                    .fill(Color.white.opacity(0.92))
                    .frame(width: 56, height: 56)
                if isPreparing {
                    RingSpinner(size: 20, color: .cnInk)
                } else {
                    Image(systemName: "play.fill")
                        .font(.system(size: 20, weight: .bold))
                        .foregroundStyle(Color.cnInk)
                }
            }
        }
        .buttonStyle(.plain)
        .disabled(isPreparing)
        .accessibilityLabel("播放")
    }

    /// 没有视频流时给一句说明，而不是一个点了没反应的播放键
    private var noStreamBadge: some View {
        HStack(spacing: 6) {
            Image(systemName: "text.alignleft")
                .font(.system(size: 11, weight: .semibold))
            Text("该内容没有视频流")
                .font(.cnCaption)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color.black.opacity(0.5), in: Capsule())
    }

    // MARK: - AI 摘要

    /// 始终读库里最新的那份。
    ///
    /// 详情页拿到的 `item` 是值拷贝：生成完写回快照后父列表会刷新，
    /// 但这一页如果只读拷贝，就永远显示「还没生成」。
    private var current: Item {
        library.items.first { $0.id == item.id } ?? item
    }

    @ViewBuilder
    private var aiSection: some View {
        if !current.aiSummary.isEmpty {
            summaryCard(current)
        } else if aiState == .running {
            runningCard
        } else if case .failed(let message) = aiState {
            failedCard(message)
        } else if aiState == .needsSetup {
            setupRow
        } else {
            // 手动模式下的常态：给一行入口，不自动花钱
            startRow
        }
    }

    private func summaryCard(_ value: Item) -> some View {
        VStack(alignment: .leading, spacing: Metric.space3) {
            HStack(spacing: 5) {
                Image(systemName: "sparkles")
                    .font(.system(size: 11, weight: .semibold))
                Text("AI 摘要")
                    .font(.cnCaption)
                Spacer(minLength: 0)
            }
            .foregroundStyle(Color.cnBrand)

            Text(value.aiSummary)
                .font(.cnBody)
                .foregroundStyle(Color.cnInk2)
                .lineSpacing(5)
                .fixedSize(horizontal: false, vertical: true)

            if !value.keyPoints.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(value.keyPoints, id: \.self) { point in
                        HStack(alignment: .top, spacing: 6) {
                            Text("·")
                                .font(.cnChip)
                                .foregroundStyle(Color.cnInk3)
                            Text(point)
                                .font(.cnChip)
                                .foregroundStyle(Color.cnInk2)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }

            if !value.labels.isEmpty {
                HStack(spacing: 6) {
                    ForEach(value.labels, id: \.self) { label in
                        Text(label)
                            .font(.cnCaption)
                            .foregroundStyle(Color.cnBrand)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(Color.cnBrandSoft, in: Capsule())
                    }
                }
            }

            // 分段放在最后：概述、要点、标签属于「扫一眼」这一层，
            // 分段是「往下读」那一层。中间那条细线就是这两层的分界。
            segmentSection(value)
        }
        .padding(Metric.space4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            Color.cnCard,
            in: RoundedRectangle(cornerRadius: Metric.radiusCard, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Metric.radiusCard, style: .continuous)
                .strokeBorder(Color.cnHairline, lineWidth: 1)
        )
    }

    private var runningCard: some View {
        HStack(spacing: Metric.space3) {
            ActivitySpinner(style: .medium)
            Text("正在生成摘要…")
                .font(.cnChip)
                .foregroundStyle(Color.cnInk3)
            Spacer(minLength: 0)
        }
        .padding(Metric.space4)
        .background(
            Color.cnCard,
            in: RoundedRectangle(cornerRadius: Metric.radiusCard, style: .continuous)
        )
    }

    private func failedCard(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: Metric.space2) {
            Text("摘要没能生成")
                .font(.cnChip)
                .foregroundStyle(Color.cnInk)
            Text(message)
                .font(.cnMeta)
                .foregroundStyle(Color.cnInk3)
                .fixedSize(horizontal: false, vertical: true)
            Button("重试") {
                aiState = .idle
                Task { await maybeSummarize() }
            }
            .font(.cnChip)
            .foregroundStyle(Color.cnBrand)
            .buttonStyle(.plain)
            .padding(.top, 2)
        }
        .padding(Metric.space4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            Color.cnCard,
            in: RoundedRectangle(cornerRadius: Metric.radiusCard, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Metric.radiusCard, style: .continuous)
                .strokeBorder(Color.cnHairline, lineWidth: 1)
        )
    }

    /// 没配置时的入口。用一行淡淡的按钮，不占一整张卡——
    /// 用户可能根本不想用 AI，不该每进一条都被推销一次。
    private var setupRow: some View {
        Button {
            showAISettings = true
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "sparkles")
                    .font(.system(size: 11, weight: .semibold))
                Text("开启 AI 摘要")
                    .font(.cnChip)
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
            }
            .foregroundStyle(Color.cnBrand)
            .padding(.horizontal, Metric.space3)
            .padding(.vertical, 10)
            .background(
                Color.cnBrandSoft,
                in: RoundedRectangle(cornerRadius: Metric.radiusButton, style: .continuous)
            )
        }
        .buttonStyle(.plain)
    }

    /// 手动模式下的一行入口。和 `setupRow` 同一套样式：
    /// 淡淡的、只占一行——用户可能根本不想用 AI，不该每进一条都被推销。
    private var startRow: some View {
        Button {
            Task { await generateSummary() }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "sparkles")
                    .font(.system(size: 11, weight: .semibold))
                Text("生成摘要")
                    .font(.cnChip)
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
            }
            .foregroundStyle(Color.cnBrand)
            .padding(.horizontal, Metric.space3)
            .padding(.vertical, 10)
            .background(
                Color.cnBrandSoft,
                in: RoundedRectangle(cornerRadius: Metric.radiusButton, style: .continuous)
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - 分段

    @ViewBuilder
    private func segmentSection(_ value: Item) -> some View {
        if !value.segments.isEmpty {
            VStack(alignment: .leading, spacing: Metric.space2) {
                Rectangle()
                    .fill(Color.cnHairlineSoft)
                    .frame(height: 1)
                    .padding(.vertical, 2)

                HStack(spacing: 5) {
                    Image(systemName: "list.number")
                        .font(.system(size: 10, weight: .semibold))
                    Text("分段")
                        .font(.cnCaption)
                    Spacer(minLength: 0)
                    if value.segments.count > previewSegmentCount {
                        Button {
                            showSegments = true
                        } label: {
                            HStack(spacing: 2) {
                                Text("全部 \(value.segments.count) 段")
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 9, weight: .semibold))
                            }
                            .font(.cnCaption)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .foregroundStyle(Color.cnInk3)

                ForEach(Array(value.segments.prefix(previewSegmentCount).enumerated()), id: \.offset) { _, segment in
                    segmentRow(segment)
                }
            }
        } else {
            segmentEntry
        }
    }

    /// 详情页露几段。3 段约占一屏，既让人确认「确实拆开讲了」，
    /// 又不至于把下面的下载按钮推出屏幕。
    private var previewSegmentCount: Int { 3 }

    private func segmentRow(_ segment: APISegment) -> some View {
        HStack(alignment: .top, spacing: Metric.space2) {
            Text(Self.mmss(segment.t))
                .font(.cnDuration)
                .foregroundStyle(Color.cnInk3)
                .frame(width: 38, alignment: .leading)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 2) {
                Text(segment.title)
                    .font(.cnChip)
                    .foregroundStyle(Color.cnInk)
                    .fixedSize(horizontal: false, vertical: true)
                if !segment.summary.isEmpty {
                    Text(segment.summary)
                        .font(.cnMeta)
                        .foregroundStyle(Color.cnInk3)
                        .lineSpacing(3)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
        }
    }

    /// 还没有分段时那一行：可能是入口，也可能正在跑、或已经明确拿不到。
    @ViewBuilder
    private var segmentEntry: some View {
        Rectangle()
            .fill(Color.cnHairlineSoft)
            .frame(height: 1)
            .padding(.vertical, 2)

        switch segmentState {
        case .running:
            HStack(spacing: Metric.space2) {
                ActivitySpinner(style: .medium)
                Text("正在按段落整理…")
                    .font(.cnMeta)
                    .foregroundStyle(Color.cnInk3)
                Spacer(minLength: 0)
            }

        case .blocked(let message):
            VStack(alignment: .leading, spacing: 4) {
                Text(message)
                    .font(.cnMeta)
                    .foregroundStyle(Color.cnInk3)
                    .fixedSize(horizontal: false, vertical: true)
                Button("重试") {
                    segmentState = .idle
                    Task { await generateSegments() }
                }
                .font(.cnCaption)
                .foregroundStyle(Color.cnBrand)
                .buttonStyle(.plain)
            }

        case .failed(let message):
            VStack(alignment: .leading, spacing: 4) {
                Text("分段没能生成：\(message)")
                    .font(.cnMeta)
                    .foregroundStyle(Color.cnInk3)
                    .fixedSize(horizontal: false, vertical: true)
                Button("重试") {
                    segmentState = .idle
                    Task { await generateSegments() }
                }
                .font(.cnCaption)
                .foregroundStyle(Color.cnBrand)
                .buttonStyle(.plain)
            }

        case .idle:
            Button {
                Task { await generateSegments() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "list.number")
                        .font(.system(size: 11, weight: .semibold))
                    Text("按段落读")
                        .font(.cnChip)
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                }
                .foregroundStyle(Color.cnBrand)
            }
            .buttonStyle(.plain)
        }
    }

    /// 进页面时自动生成一次。默认**不**跑：AI 是用户自己的额度。
    private func maybeSummarize() async {
        guard autoSummary else { return }
        await generateSummary()
    }

    private func generateSummary() async {
        guard !library.isOffline, current.aiSummary.isEmpty, aiState != .running else { return }

        let config = AIConfigStore.load()
        guard config.isConfigured else {
            aiState = .needsSetup
            return
        }

        aiState = .running
        do {
            let result = try await Summarizer(config: config).summarize(
                title: current.title,
                description: current.summary,
                platform: current.metaLine,
                duration: current.durationText
            )
            let saved = await library.saveSummary(
                id: current.id, result: result, by: config.model
            )
            aiState = saved ? .idle : .failed("生成成功，但没存上。检查网络后再试。")
        } catch let failure as SummarizeFailure {
            aiState = .failed(failure.displayMessage)
        } catch {
            aiState = .failed("生成失败：\(error.localizedDescription)")
        }
    }

    /// 自动模式才跑，且只在「秒级可得」这条路上跑——
    /// 需要转写的条目仍然等用户点，否则进页面就开始烧几分钟电。
    private func maybeLoadSegments() async {
        guard autoSummary else { return }
        await generateSegments()
    }

    private func generateSegments() async {
        guard !library.isOffline, current.segments.isEmpty, segmentState != .running else { return }

        let config = AIConfigStore.load()
        guard config.isConfigured else {
            segmentState = .blocked("还没配置 AI 服务。先点上面的「开启 AI 摘要」。")
            return
        }

        segmentState = .running
        do {
            let transcript = try await library.transcript(for: current.id)
            guard transcript.source == "subtitle", !transcript.lines.isEmpty else {
                // 服务端已经解释了为什么拿不到，照抄比另编一句准
                segmentState = .blocked(
                    transcript.reason.isEmpty ? "这条没有可用字幕。" : transcript.reason
                )
                return
            }
            let segments = try await Segmenter(config: config).segments(
                title: current.title,
                lines: transcript.lines,
                durationSeconds: transcript.durationSeconds
            )
            // 字幕只覆盖前半段时，模型没见过结尾，只能按见到的东西收尾。
            // 与其让它假装讲完了，不如把这件事写在卡片上。
            if transcript.partial {
                let minutes = max(1, transcript.lines.last.map { $0.t } ?? 0) / 60
                notice = "字幕只覆盖到第 \(minutes) 分钟，后面的内容没有算进去。"
            }
            let saved = await library.saveSegments(
                id: current.id, segments: segments, by: config.model
            )
            segmentState = saved ? .idle : .failed("生成成功，但没存上。")
        } catch let failure as SummarizeFailure {
            segmentState = .failed(failure.displayMessage)
        } catch {
            segmentState = .failed(failureMessage(error))
        }
    }

    private func failureMessage(_ error: Error) -> String {
        if let failure = error as? ClipNoteClient.Failure {
            return failure.displayMessage
        }
        return error.localizedDescription
    }

    static func mmss(_ seconds: Int) -> String {
        let value = max(0, seconds)
        return String(format: "%02d:%02d", value / 60, value % 60)
    }

    // MARK: - 取地址

    /// 进页面时预取。失败不弹提示——用户还没点任何东西，不该先被红字吓一下。
    private func prefetch() async {
        // 截图/预览模式没有网络层：此时不能把「没配 client」显示成「取不到地址」，
        // 否则每张详情图都会挂一条红字，而它反映的不是产品行为。
        guard !library.isOffline else { return }
        guard item.playbackAvailable, prepare == .idle else { return }
        _ = await ensurePlayback(silent: true)
    }

    /// 拿播放地址。已有就复用，没有就取一次；失败后再调用即「手动重试」。
    private func ensurePlayback(silent: Bool = false) async -> APIPlaybackPayload? {
        switch prepare {
        case .ready(let payload):
            return payload
        case .loading:
            return nil
        case .unavailable:
            if !silent { notice = "该内容没有视频流。" }
            return nil
        case .unsupported(let message):
            if !silent { notice = message }
            return nil
        case .idle, .failed:
            break
        }

        prepare = .loading
        if !silent { notice = nil }
        do {
            if let payload = try await library.playback(for: item.id) {
                prepare = .ready(payload)
                return payload
            }
            prepare = .unavailable
            if !silent { notice = "该内容没有视频流。" }
            return nil
        } catch let failure as ClipNoteClient.Failure {
            // 501 是「平台没接」，不是「这次失败」。重试一万次也还是一样。
            if case .http(let status, _, let message) = failure, status == 501 {
                let text = message ?? "这个平台的视频暂时还无法重新播放。"
                prepare = .unsupported(text)
                if !silent { notice = text }
                return nil
            }
            prepare = .failed(failure.displayMessage)
            if !silent { notice = failure.displayMessage }
            return nil
        } catch {
            let message = "取播放地址失败，请稍后重试。"
            prepare = .failed(message)
            if !silent { notice = message }
            return nil
        }
    }

    // MARK: - 播放

    private func startPlayback() async {
        // 已下载优先：本地文件离线可看，也不必再去要一次地址
        if let local = downloads.localURL(for: item.id) {
            play(local)
            return
        }

        if let player {
            player.play()
            playing = true
            return
        }

        guard let payload = await ensurePlayback(),
              let url = URL(string: payload.url) else { return }
        play(url)
    }

    private func play(_ url: URL) {
        let playerItem = AVPlayerItem(url: url)
        let newPlayer = AVPlayer(playerItem: playerItem)
        player = newPlayer
        playing = true
        notice = nil
        let isLocal = url.isFileURL
        logs.info("playback.started", isLocal ? "开始播放（本地文件）" : "开始播放（服务端代理）",
                  meta: ["host": isLocal ? "local" : (url.host ?? "-")])

        // 地址过期时 AVPlayer **不会**抛错，它只是一直转圈。
        // 不观察 status 的话，用户看到的就是「点了没反应」——最差的一种失败。
        statusObservation = playerItem.observe(\.status, options: [.new]) { observed, _ in
            guard observed.status == .failed else { return }
            Task { @MainActor in
                playing = false
                player = nil
                // 退回 idle，下次点播放会自动重新取一次地址
                prepare = .idle
                notice = "这个视频暂时播不了，地址可能已经过期。再点一次播放会重新取。"
                logs.error("playback.failed", "AVPlayer 加载失败（status = failed）", meta: [
                    "host": isLocal ? "local" : (url.host ?? "-"),
                    "error": observed.error?.localizedDescription ?? "-",
                ])
            }
        }

        newPlayer.play()
    }

    // MARK: - 下载区

    @ViewBuilder
    private var downloadSection: some View {
        VStack(alignment: .leading, spacing: Metric.space3) {
            if !item.playbackAvailable {
                Text("这条内容以文字为主，没有可下载的视频。")
                    .font(.cnMeta)
                    .foregroundStyle(Color.cnInk3)
                    .fixedSize(horizontal: false, vertical: true)

            } else if downloads.isDownloaded(item.id) {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 13, weight: .semibold))
                    Text("已下载 · \(sizeText) · 存于本机，离线可看")
                        .font(.cnMeta)
                }
                .foregroundStyle(Color.cnGreen)

                PrimaryButton(title: playing ? "正在播放" : "在本地播放") {
                    Task { await startPlayback() }
                }

            } else if let value = downloads.progressValue(for: item.id) {
                DownloadProgressCard(progress: value) {
                    downloads.cancel(item.id)
                }

                Text("下载在后台继续，离开此页不会中断。")
                    .font(.cnMeta)
                    .foregroundStyle(Color.cnInk3)

            } else {
                PrimaryButton(title: "下载到本地", isLoading: isPreparing) {
                    Task { await startDownload() }
                }

                Text(prepareHint)
                    .font(.cnMeta)
                    .foregroundStyle(Color.cnInk3)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// 按钮下面那行字：把「要下多大」说在前面
    private var prepareHint: String {
        switch prepare {
        case .ready(let payload):
            let summary = payload.sizeSummary
            return summary.isEmpty
                ? "地址会过期，失效时自动重新解析。"
                : "\(summary) · 地址失效时自动重新解析。"
        case .failed(let message):
            return "\(message) 点上面的按钮可以重试。"
        case .unsupported(let message):
            return message
        case .unavailable:
            return "该内容没有可下载的视频。"
        case .idle, .loading:
            return "地址会过期，失效时自动重新解析。"
        }
    }

    private func startDownload() async {
        guard let payload = await ensurePlayback(),
              let url = URL(string: payload.url) else { return }
        downloads.start(item.id, url: url)
    }

    private var sizeText: String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useMB, .useGB]
        formatter.countStyle = .file
        formatter.allowsNonnumericFormatting = false
        return formatter.string(fromByteCount: downloads.byteCount(for: item.id))
    }
}

// MARK: - 下载进度卡（画布 07）

struct DownloadProgressCard: View {
    var progress: Double
    var onCancel: () -> Void

    var body: some View {
        HStack(spacing: Metric.space3) {
            ZStack {
                Circle()
                    .stroke(Color.cnCard3, lineWidth: 3)
                Circle()
                    .trim(from: 0, to: max(0.02, min(1, progress)))
                    .stroke(Color.cnBrand, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Text("\(Int((progress * 100).rounded()))%")
                    .font(.custom("Inter-SemiBold", size: 10, relativeTo: .caption2))
                    .foregroundStyle(Color.cnInk)
            }
            .frame(width: 44, height: 44)

            VStack(alignment: .leading, spacing: 3) {
                Text("正在下载")
                    .font(.cnRowTitle)
                    .foregroundStyle(Color.cnInk)
                Text("可离开此页，后台继续")
                    .font(.cnMeta)
                    .foregroundStyle(Color.cnInk3)
            }

            Spacer(minLength: 0)

            Button("取消", action: onCancel)
                .font(.cnChip)
                .foregroundStyle(Color.cnRed)
                .buttonStyle(.plain)
                .accessibilityLabel("取消下载")
        }
        .padding(Metric.space3)
        .background(
            Color.cnCard,
            in: RoundedRectangle(cornerRadius: Metric.radiusCard, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Metric.radiusCard, style: .continuous)
                .strokeBorder(Color.cnHairline, lineWidth: 1)
        )
    }
}
