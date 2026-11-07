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
    /// 分段导航里高亮哪一段。只反映「上次点了哪块」，不跟播放进度走——
    /// 跟进度要挂定时器，那是另一件事（progress bar），先不混进来。
    @State private var activeSegment: Int?
    /// 正在用当前模型重做这条的 AI 内容。和 `aiState` 分开：
    /// 重做时旧摘要要继续显示，不能让卡片先变成「正在生成」再跳回来。
    @State private var refreshing = false
    /// 正在编辑的书签。nil 表示编辑面板没开。
    @State private var editingBookmark: BookmarkDraft?
    /// 周期性记录播放进度的观察者，换播放器时要先摘掉
    @State private var timeObserver: Any?
    /// 跳到书签后临时显示的那行（时间 + 备注），3 秒后自己消失
    @State private var bookmarkHint: String?
    @State private var suggesting = false
    @State private var suggestions: [APIBookmark] = []
    @State private var showSuggest = false
    @State private var editingAuthorNote = false
    @State private var showNote = false
    @State private var showOutline = false
    @State private var showRelink = false
    @State private var showTranscript = false
    @State private var showTemplates = false
    @State private var showInfographic = false
    @State private var showTranscribe = false
    @State private var notice: String?
    @State private var statusObservation: NSKeyValueObservation?
    @State private var prepare: PrepareState = .idle
    /// 进页面要不要自动总结。默认**不自动**：AI 是用户自己的额度，
    /// 只是路过看一眼不该先花一次调用。设置里可以改成自动。
    @AppStorage("clipnote.autoSummary") private var autoSummary = false

    /// `initialPrepare` 只给截图用：让「已取到地址」这一态可被拍下来。
    /// 正常路径一律 `.idle`，由 `prefetch()` 去取。
    /// 从搜索结果进来时，直接落到字幕页的这一句。
    var focusTranscriptAt: Int? = nil

    init(item: Item, initialPrepare: PrepareState? = nil, focusTranscriptAt: Int? = nil) {
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

                // 书签这一行：时间轴 + 标记按钮。
                // 不再是「有书签才显示」——没有书签时也要有地方可以标。
                if item.playbackAvailable {
                    bookmarkBar
                }

                if let bookmarkHint {
                    Text(bookmarkHint)
                        .font(.cnCaption)
                        .foregroundStyle(Color.cnInk3)
                        .lineLimit(2)
                        .padding(.horizontal, Metric.pagePad)
                        .padding(.top, 4)
                        .transition(.opacity)
                }

                // 分段条贴在播放器正下方，常驻可见。
                // 进独立页再点时间戳那条路绕得太远——用户想的是「跳到第 3 分钟」，
                // 不是「先去读一遍目录」。
                if !current.segments.isEmpty {
                    segmentRail
                }

                VStack(alignment: .leading, spacing: Metric.space3) {
                    Text(item.title)
                        .font(.cnTitle)
                        .foregroundStyle(Color.cnInk)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)

                    authorRow

                    Text(metaLine)
                        .font(.cnMeta)
                        .foregroundStyle(Color.cnInk3)

                    videoLinkRow

                    // 笔记放在摘要**之前**：首屏能看见。
                    // 原来放在「简介」后面，而那时屏幕已经被播放器、标题、
                    // 作者、AI 摘要卡占满——真机上用户直接问「笔记在哪」。
                    noteRow

                    aiSection

                    outlineRow

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
            // 常驻入口：不管滚到哪儿都能进笔记。
            // 页面里的卡片会随滚动消失，而「我的笔记」是用户随时可能想写的地方。
            ToolbarItem(placement: .navigationBarTrailing) {
                Button {
                    showNote = true
                } label: {
                    Image(systemName: current.note.isEmpty ? "square.and.pencil" : "pencil.line")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(current.note.isEmpty ? Color.cnInk2 : Color.cnBrand)
                }
                .accessibilityLabel(current.note.isEmpty ? "写笔记" : "编辑笔记")
            }
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
        // 用 push 而不是 fullScreenCover：模态页在 iOS 上由 SwiftUI 自己创建
        // 宿主控制器，那个控制器固定返回 `portrait`，于是
        // `requestGeometryUpdate(landscape)` 一定被拒——真机日志里
        // 「受支持：portrait」就是这么来的。push 进同一个导航栈后，
        // 顶层控制器回到根宿主（支持全部方向），转屏才有机会成功。
        .navigationDestination(isPresented: $showFullscreen) {
            PlayerScreen(item: item, player: player)
        }
        // 进页面就先取一次地址：这样「下载到本地」旁边能标出体积，
        // 而不是让用户点下去才知道下多大。有 5 分钟缓存，来回切页不会重复打上游。
        .task {
            await prefetch()
            await maybeSummarize()
            await maybeLoadSegments()
        }
        .navigationDestination(isPresented: $showOutline) {
            OutlineScreen(item: current)
        }
        // 从搜索结果点「字幕命中」进来：直接把字幕页推到最上面。
        // 延迟一点是为了让详情页先完成推入动画，否则会出现两级导航同时动。
        .onAppear {
            guard focusTranscriptAt != nil, !showTranscript else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                showTranscript = true
            }
        }
        .navigationDestination(isPresented: $showTranscript) {
            TranscriptScreen(item: current, focusAt: focusTranscriptAt)
        }
        .navigationDestination(isPresented: $showNote) {
            NoteScreen(item: current)
        }
        .navigationDestination(isPresented: $showSegments) {
            SegmentsScreen(item: current)
        }
        .sheet(isPresented: $showAISettings) {
            NavigationStack { AISettingsScreen() }
        }
        // 长图的入口在摘要卡里（见 `infographicButton`），这里只负责呈现。
        .sheet(isPresented: $showInfographic) {
            InfographicSheet(item: current)
        }
        // 本机转写：入口在「没有字幕」那一态（见 `segmentEntry`）。
        // 转写完立刻拿文字去切分段——用户点这一步的意图本来就是「想按段落读」，
        // 再让他回去点第二次没有必要。
        .sheet(isPresented: $showTranscribe) {
            TranscribeSheet(item: current) { _ in
                segmentState = .idle
                Task { await generateSegments(force: true) }
            }
            .presentationDetents([.medium, .large])
        }
        .onDisappear {
            // 离开这一页必须收声，并记住看到哪儿。
            // onDisappear 不保证一定执行（手势被取消时可能不触发），
            // 所以真正的兜底在 AudioFocus —— 下一次起播会先掐掉旧的。
            if let player {
                let seconds = player.currentTime().seconds
                if seconds.isFinite, seconds > 0 {
                    PlaybackMemory.shared.remember(seconds, for: item.id)
                }
            }
            AudioFocus.shared.resign(player)
            if let timeObserver, let player {
                player.removeTimeObserver(timeObserver)
            }
            timeObserver = nil
        }
        .sheet(isPresented: $showTemplates) {
            TemplateSheet { _, _ in
                // 只重写摘要。分段/书签/脑图不动——换结构不该让别的东西跟着变。
                Task { await generateSummary(force: true) }
            }
        }
        .sheet(isPresented: $showRelink) {
            RelinkSheet(item: current) {
                notice = "链接补上了，作者主页和原视频现在能直达。"
            }
        }
        .sheet(isPresented: $editingAuthorNote) {
            AuthorNoteSheet(
                author: current.author,
                original: current.authorNote,
                draftSource: AuthorNoteDraft.make(from: current)
            ) { note in
                Task {
                    let ok = await library.saveAuthorNote(id: current.id, note: note)
                    if !ok { notice = "作者备注没存上，检查网络。" }
                }
            }
        }
        .sheet(isPresented: $showSuggest) {
            BookmarkSuggestSheet(suggestions: suggestions) { chosen in
                var list = current.bookmarks
                list.append(contentsOf: chosen)
                Task { await persistBookmarks(list) }
            }
        }
        .sheet(item: $editingBookmark) { draft in
            BookmarkEditSheet(
                draft: draft,
                onSave: { note in
                    var list = current.bookmarks
                    if let index = list.firstIndex(where: { $0.t == draft.t }) {
                        list[index].note = note.trimmingCharacters(in: .whitespacesAndNewlines)
                    }
                    Task { await persistBookmarks(list) }
                },
                onDelete: {
                    let list = current.bookmarks.filter { $0.t != draft.t }
                    Task { await persistBookmarks(list) }
                }
            )
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

    /// 作者那一条。
    ///
    /// 分两个点按区：上面一行进作者主页，下面一行编辑备注。
    /// 不做成「整行一个按钮再长按编辑」——长按在这里没有可见提示，
    /// 用户永远不会发现备注可以改。
    @ViewBuilder
    private var authorRow: some View {
        if !current.displayAuthor.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Button {
                    // 只有拿到 mid 才跳。没有就明说原因——
                    // 退到「按名字搜」看似友好，实际会在 UP 主改名后把人带错地方。
                    if !PlatformLink.openAuthor(current) {
                        notice = "这条没有作者主页链接：它是早先导入的，缺 UP 主 ID。重新导入一次这条视频就能直达。"
                    }
                } label: {
                    HStack(spacing: Metric.space2) {
                        avatarView
                        Text(current.displayAuthor)
                            .font(.cnChip)
                            .foregroundStyle(Color.cnInk)
                            .lineLimit(1)
                        if !current.authorId.isEmpty {
                            Text("主页")
                                .font(.cnCaption)
                                .foregroundStyle(Color.cnInk3)
                            Image(systemName: "chevron.right")
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(Color.cnInk3)
                        }
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                Button {
                    editingAuthorNote = true
                } label: {
                    Text(current.authorNote.isEmpty ? "＋ 写一句作者备注" : current.authorNote)
                        .font(.cnCaption)
                        .foregroundStyle(current.authorNote.isEmpty ? Color.cnBrand : Color.cnInk2)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.leading, 38)   // 和上面的名字对齐，跳过头像
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    /// 头像。有地址就加载真图，没有就画首字母——
    /// 老数据一律没有地址，空白圆圈比首字母更像「坏了」。
    private var avatarView: some View {
        ZStack {
            Circle().fill(Color.cnBrandSoft)
            if let url = URL(string: current.authorAvatar), !current.authorAvatar.isEmpty {
                AsyncImage(url: url, transaction: Transaction(animation: nil)) { phase in
                    if case .success(let image) = phase {
                        image.resizable().scaledToFill()
                    } else {
                        fallbackInitial
                    }
                }
                .clipShape(Circle())
            } else {
                fallbackInitial
            }
        }
        .frame(width: 30, height: 30)
        .clipShape(Circle())
    }

    private var fallbackInitial: some View {
        Text(String(current.displayAuthor.prefix(1)))
            .font(.cnChip)
            .foregroundStyle(Color.cnBrand)
    }

    @ViewBuilder
    private var videoLinkRow: some View {
        if current.platform == "bilibili" || !current.sourceURL.isEmpty {
            // 有地址就「打开」，没地址就「补上」——同一个位置，两种语义。
            // 之前没地址时只弹一句「重新导入一次」，等于把活推回给用户。
            let hasLink = !current.videoId.isEmpty || !current.sourceURL.isEmpty
            Button {
                if hasLink {
                    if !PlatformLink.openVideo(current) {
                        showRelink = true
                    }
                } else {
                    showRelink = true
                }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: hasLink ? "arrow.up.right.square" : "link.badge.plus")
                        .font(.system(size: 10, weight: .semibold))
                    Text(hasLink ? "原视频" : "补原始链接")
                        .font(.cnCaption)
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                }
                .foregroundStyle(hasLink ? Color.cnInk3 : Color.cnBrand)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    /// 服务端已经给好 `metaLine` 和 `durationText`，这里只负责摆位置。
    ///
    /// 但要把作者名摘掉：`metaLine` 的格式是「平台 · 作者」，
    /// 而作者现在单独占一行（可点、带备注）。两处都显示名字会显得啰嗦，
    /// 也让「点哪个进主页」变得不明确。
    private var metaLine: String {
        let parts = item.metaLine
            .split(separator: "·")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && $0 != current.displayAuthor }
        var text = parts.joined(separator: " · ")
        if !item.durationText.isEmpty {
            text = text.isEmpty ? item.durationText : "\(text) · \(item.durationText)"
        }
        return text
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

    /// 书签这一行：左边是时间轴上的旗子，右边是「标记」。
    ///
    /// 「标记」原来浮在画面右上角，**和系统的音量/AirPlay 控件叠在一起**，
    /// 点十次有八次点到系统控件。系统控件的位置我们改不了，只能让开——
    /// 挪到画面外面这一行，和书签本身待在一起，语义也更顺。
    private var bookmarkBar: some View {
        HStack(spacing: Metric.space2) {
            bookmarkRail
            suggestButton
            markButton
        }
        .padding(.horizontal, Metric.pagePad)
        .padding(.top, Metric.space2)
    }

    /// 「让模型挑三个点」。只在已经有字幕的条目上有意义——
    /// 没字幕时它和分段是同一个失败原因，没必要占用这一行的位置。
    private var suggestButton: some View {
        Button {
            Task { await suggestBookmarks() }
        } label: {
            Group {
                if suggesting {
                    RingSpinner(size: 12, color: .cnBrand)
                } else {
                    Image(systemName: "sparkles")
                        .font(.system(size: 12, weight: .semibold))
                }
            }
            .foregroundStyle(Color.cnBrand)
            .frame(width: 30, height: 26)
            .background(Color.cnBrandSoft, in: Capsule())
        }
        .buttonStyle(.plain)
        .disabled(suggesting || player == nil)
        .opacity(player == nil ? 0.4 : 1)
        .accessibilityLabel("让模型挑三个值得回看的点")
    }

    /// 播放器下方那一行里的「标记」。
    private var markButton: some View {
        Button {
            Task { await addBookmarkAtCurrentTime() }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "flag.badge.plus")
                    .font(.system(size: 10, weight: .semibold))
                Text("标记")
                    .font(.cnCaption)
            }
            .foregroundStyle(player == nil ? Color.cnInk3 : Color.cnBrand)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(
                player == nil ? Color.cnCard3 : Color.cnBrandSoft,
                in: Capsule()
            )
        }
        .buttonStyle(.plain)
        .disabled(player == nil)
        .accessibilityLabel("把当前位置标成书签")
    }

    // MARK: - 分段导航

    /// 播放器正下方的分段导航：一排可横滑的标题块，点一下跳到那一段。
    ///
    /// 为什么不是「按时间比例分块」：试过，读不出来。
    /// 段与段时间长度差 5 倍时，窄的那块放不下序号，宽的那块又像留白；
    /// 9 块并排看过去只是一排灰方块，用户第一眼不知道那是什么。
    /// 标题块牺牲了「按比例」的直觉，换回「我点进去的是哪一段」这件更重要的事。
    ///
    /// 为什么不塞进播放器控件：全屏走系统 `AVPlayerViewController`，改不了；
    /// 详情页这个播放器一开播，系统控件就盖满画面。放在画面外面才两全。
    private var segmentRail: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(Array(current.segments.enumerated()), id: \.offset) { index, segment in
                    Button {
                        activeSegment = segment.t
                        Task { await startPlayback(at: segment.t) }
                    } label: {
                        HStack(spacing: 6) {
                            Text(String(format: "%02d", index + 1))
                                .font(.custom("Inter-SemiBold", size: 10, relativeTo: .caption2))
                                .foregroundStyle(Color.cnBrand)
                            Text(segment.title)
                                .font(.cnChip)
                                .foregroundStyle(Color.cnInk)
                                .lineLimit(1)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .background(
                            activeSegment == segment.t ? Color.cnBrandSoft : Color.cnCard3,
                            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .strokeBorder(
                                    activeSegment == segment.t ? Color.cnBrand : Color.clear,
                                    lineWidth: 1
                                )
                        )
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("从 \(Self.mmss(segment.t)) 开始播放：\(segment.title)")
                }
            }
            .padding(.horizontal, Metric.pagePad)
        }
        .padding(.top, Metric.space3)
        .padding(.bottom, Metric.space1)
    }

    /// 摘要卡角上那个刷新键。
    ///
    /// 存在的理由很具体：换了模型之后，旧摘要还是旧模型写的，
    /// 用户没有任何办法「拿新模型再写一遍」——只能删库重导。这不合理。
    private var refreshButton: some View {
        Button {
            Task { await refreshAI() }
        } label: {
            HStack(spacing: 4) {
                if refreshing {
                    RingSpinner(size: 10, color: .cnBrand)
                } else {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 10, weight: .semibold))
                }
                Text(refreshing ? "正在重写" : "重写")
                    .font(.cnCaption)
            }
            .foregroundStyle(Color.cnBrand)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Color.cnBrandSoft, in: Capsule())
        }
        .buttonStyle(.plain)
        .disabled(refreshing)
        .accessibilityLabel("用当前模型重新生成摘要")
    }

    /// 摘要卡角上那个「长图」。
    ///
    /// 为什么和「重写」并排：两者是同一层的操作——都是对**这份摘要**做的事。
    /// 放进导航栏会和「笔记」抢位置（那里已经有一个常驻入口）；
    /// 放到卡片底部则会被推到折叠线以下——详情页首屏到摘要卡标题行就到头了，
    /// 这条是踩过的坑：「排在简介之后等于用户看不见」。
    private var infographicButton: some View {
        Button {
            showInfographic = true
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "doc.text.image")
                    .font(.system(size: 10, weight: .semibold))
                Text("长图")
                    .font(.cnCaption)
            }
            .foregroundStyle(Color.cnBrand)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Color.cnBrandSoft, in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("把摘要和分段排成一页长图")
    }

    /// 用**当前配置的模型**把这条的 AI 内容重做一遍。
    ///
    /// 顺序有讲究：先摘要再分段。摘要是用户点这个按钮想看的，
    /// 而分段要拉字幕、跑一次长输出，把它放前面会让用户等十几秒才看到摘要变了。
    /// 分段失败不回滚摘要——两者各自独立，一个挂了不该连累另一个。
    private func refreshAI() async {
        guard !library.isOffline, !refreshing else { return }
        let config = AIConfigStore.load()
        guard config.isConfigured else {
            aiState = .needsSetup
            return
        }

        refreshing = true
        activeSegment = nil
        defer { refreshing = false }

        logs.info("ai.refresh", "用当前模型重写", meta: [
            "id": current.id, "model": config.model,
            "hasSegments": current.segments.isEmpty ? "0" : "1",
        ])
        await generateSummary(force: true)
        if !current.segments.isEmpty {
            await generateSegments(force: true)
        }
    }

    // MARK: - 书签

    /// 书签轨道：按时间比例把旗子摆在一条细线上。
    ///
    /// 和分段导航的区别必须做出来——分段是 AI 给的目录（等宽块 + 序号），
    /// 书签是人插的旗（细线 + 旗子 + 按比例）。两种东西混成一样，
    /// 用户就分不清哪个是自己标的了。
    private var bookmarkRail: some View {
        GeometryReader { geo in
            let width = max(1, geo.size.width)
            let total = Double(max(1, current.durationSeconds))

            ZStack(alignment: .topLeading) {
                Rectangle()
                    .fill(Color.cnHairline)
                    .frame(height: 1)
                    .frame(maxHeight: .infinity, alignment: .center)

                ForEach(Array(current.bookmarks.enumerated()), id: \.offset) { _, bookmark in
                    Image(systemName: "flag.fill")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Color.cnBrand)
                        .padding(6)          // 触摸区比图形大一圈
                        .contentShape(Rectangle())
                        // 点击 = 跳过去。这一条是被真机反馈纠正的：
                        // 原来的点击是「打开编辑面板」，而用户的预期是「和分段一样跳转」。
                        // 编辑属于次级操作，放长按。
                        .onTapGesture {
                            Task { await jump(to: bookmark) }
                        }
                        .onLongPressGesture {
                            editingBookmark = BookmarkDraft(
                                t: bookmark.t, note: bookmark.note, by: bookmark.by
                            )
                        }
                        .position(
                            // 贴边的那几个要往内收，否则一半在屏幕外点不到
                            x: min(max(10, CGFloat(Double(bookmark.t) / total) * width), width - 10),
                            y: geo.size.height / 2
                        )
                }
            }
        }
        .frame(height: 26)
    }

    /// 让模型从字幕里挑三个值得回看的点，作为**建议**列出来。
    ///
    /// 复用已有的转写链路：`library.transcript` 有缓存，刚跑过分段的话
    /// 这一步几乎不花时间。
    private func suggestBookmarks() async {
        guard !library.isOffline, !suggesting else { return }
        let config = AIConfigStore.load()
        guard config.isConfigured else {
            aiState = .needsSetup
            return
        }

        suggesting = true
        defer { suggesting = false }

        do {
            let transcript = try await library.transcript(for: current.id)
            guard transcript.source == "subtitle", !transcript.lines.isEmpty else {
                notice = "这条没有字幕，模型没法挑点。"
                return
            }
            let list = try await BookmarkSuggestor(config: config).suggest(
                title: current.title,
                lines: transcript.lines,
                existing: current.bookmarks
            )
            logs.info("bookmarks.suggested", "给出书签建议", meta: [
                "id": current.id, "count": String(list.count), "model": config.model,
            ])
            suggestions = list
            showSuggest = true
        } catch let failure as SummarizeFailure {
            notice = failure.displayMessage
            logs.error("bookmarks.suggest_failed", failure.displayMessage,
                       meta: ["id": current.id])
        } catch {
            notice = "给建议失败：\(error.localizedDescription)"
        }
    }

    /// 跳到某个书签。没在播就先起播，已经在播就 seek。
    private func jump(to bookmark: APIBookmark) async {
        await startPlayback(at: bookmark.t)
        // 把备注亮在播放器正下方：否则用户点完只看到画面变了，
        // 不知道自己当初为什么标这一下。
        bookmarkHint = bookmark.note.isEmpty
            ? "已跳到 \(Self.mmss(bookmark.t))"
            : "\(Self.mmss(bookmark.t))　\(bookmark.note)"
        let shown = bookmarkHint
        try? await Task.sleep(nanoseconds: 3_000_000_000)
        if bookmarkHint == shown { bookmarkHint = nil }
    }

    /// 把当前位置标成书签。
    private func addBookmarkAtCurrentTime() async {
        guard let player else { return }
        let seconds = player.currentTime().seconds
        guard seconds.isFinite, seconds >= 0 else { return }
        let t = Int(seconds)

        // 3 秒内重复点不算新书签：点两下很常见，多出来一条只会让人困惑
        if current.bookmarks.contains(where: { abs($0.t - t) < 3 }) {
            notice = "\(Self.mmss(t)) 这一带已经标过了。"
            return
        }

        var list = current.bookmarks
        list.append(APIBookmark(t: t))
        await persistBookmarks(list)
        notice = "已标记 \(Self.mmss(t))。"
    }

    private func persistBookmarks(_ list: [APIBookmark]) async {
        let sorted = list.sorted { $0.t < $1.t }
        let ok = await library.saveBookmarks(id: current.id, bookmarks: sorted)
        if !ok {
            notice = "书签没存上，检查网络后再试。"
        }
    }

    private var playButton: some View {        Button {
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
                // 模板名直接露在标题行：换模板是「改结构」，
                // 属于这一块内容的属性，不该藏进二级菜单。
                Button {
                    showTemplates = true
                } label: {
                    HStack(spacing: 2) {
                        Text(SummaryTemplateStore.load().title)
                            .font(.cnMeta)
                        Image(systemName: "chevron.down")
                            .font(.system(size: 7, weight: .semibold))
                    }
                    .foregroundStyle(Color.cnInk3)
                }
                .buttonStyle(.plain)
                Spacer(minLength: 0)
                infographicButton
                refreshButton
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
                    // 标签是**入口**不是装饰：点了应该能看到同类内容。
                    // 去的是和「我 · 标签」同一个页面，只是直接落在分类里。
                    ForEach(value.labels, id: \.self) { label in
                        NavigationLink {
                            TagItemsScreen(tag: label)
                        } label: {
                            Text(label)
                                .font(.cnCaption)
                                .foregroundStyle(Color.cnBrand)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(Color.cnBrandSoft, in: Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                    Spacer(minLength: 0)
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
            // 只留一行入口。分段内容已经在播放器下方那排导航里了，
            // 卡片里再列一遍等于同一份信息出现两次。
            Rectangle()
                .fill(Color.cnHairlineSoft)
                .frame(height: 1)
                .padding(.vertical, 2)

            Button {
                showSegments = true
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "list.number")
                        .font(.system(size: 10, weight: .semibold))
                    Text("分段 · \(value.segments.count) 段")
                        .font(.cnCaption)
                    Spacer(minLength: 0)
                    Text("通读")
                        .font(.cnCaption)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                }
                .foregroundStyle(Color.cnInk3)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Rectangle()
                .fill(Color.cnHairlineSoft)
                .frame(height: 1)
                .padding(.vertical, 2)

            // 字幕和分段并排：分段是结构，字幕是原话。
            // 字幕的出口不是「读」，而是「带走」——复制全文或导出 SRT。
            Button {
                showTranscript = true
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "text.alignleft")
                        .font(.system(size: 10, weight: .semibold))
                    Text("字幕")
                        .font(.cnCaption)
                    Spacer(minLength: 0)
                    Text("可复制 / 导出 SRT")
                        .font(.cnCaption)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                }
                .foregroundStyle(Color.cnInk3)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        } else {
            segmentEntry
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

                // 「没有字幕」不是死路：音轨还在，系统听写能出文字。
                // 所以这里给两条路——重试（等平台补字幕）和本机转写（自己动手）。
                HStack(spacing: Metric.space4) {
                    Button("重试") {
                        segmentState = .idle
                        Task { await generateSegments() }
                    }
                    .font(.cnCaption)
                    .foregroundStyle(Color.cnBrand)
                    .buttonStyle(.plain)

                    Button("本机转写") {
                        showTranscribe = true
                    }
                    .font(.cnCaption)
                    .foregroundStyle(Color.cnBrand)
                    .buttonStyle(.plain)
                }
                .padding(.top, 2)
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
            VStack(alignment: .leading, spacing: 6) {
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

                // 抖音/小红书本来就可能没字幕。等失败一次再给入口等于让用户先撞墙，
                // 所以第一次进来就把这条路摆出来，用弱化的样式，不抢主按钮。
                Button("没有字幕？用本机转写") {
                    showTranscribe = true
                }
                .font(.cnCaption)
                .foregroundStyle(Color.cnInk3)
                .buttonStyle(.plain)
            }
        }
    }

    /// 进页面时自动生成一次。默认**不**跑：AI 是用户自己的额度。
    private func maybeSummarize() async {
        guard autoSummary else { return }
        await generateSummary()
    }

    private func generateSummary(force: Bool = false) async {
        guard !library.isOffline, aiState != .running else { return }
        guard force || current.aiSummary.isEmpty else { return }

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
            // 已有摘要时卡片不会切到失败态（旧内容留着更好），
            // 所以失败必须另找地方说，否则用户以为「点了没反应」
            notice = failure.displayMessage
        } catch {
            aiState = .failed("生成失败：\(error.localizedDescription)")
            notice = "重写失败：\(error.localizedDescription)"
        }
    }

    /// 自动模式才跑，且只在「秒级可得」这条路上跑——
    /// 需要转写的条目仍然等用户点，否则进页面就开始烧几分钟电。
    private func maybeLoadSegments() async {
        guard autoSummary else { return }
        await generateSegments()
    }

    private func generateSegments(force: Bool = false) async {
        guard !library.isOffline, segmentState != .running else { return }
        guard force || current.segments.isEmpty else { return }

        let config = AIConfigStore.load()
        guard config.isConfigured else {
            segmentState = .blocked("还没配置 AI 服务。先点上面的「开启 AI 摘要」。")
            return
        }

        segmentState = .running
        do {
            let transcript = try await library.transcript(for: current.id)

            // 字幕优先：服务端解析好的那份秒级可得。
            // 没有就退到**本机转写**那份——抖音/小红书本来就没字幕，
            // 而它们的音轨就躺在视频里，系统听写能出文字。
            // 本机这份存在 Documents 下，服务端同步覆盖不到，所以能一直复用。
            var lines: [APITranscriptLine]
            var duration: Int
            var subtitleOnlyNotice: String?

            if transcript.source == "subtitle", !transcript.lines.isEmpty {
                lines = transcript.lines
                duration = transcript.durationSeconds
                // 字幕只覆盖前半段时，模型没见过结尾，只能按见到的东西收尾。
                // 与其让它假装讲完了，不如把这件事写在卡片上。
                if transcript.partial {
                    let minutes = max(1, transcript.lines.last.map { $0.t } ?? 0) / 60
                    subtitleOnlyNotice = "字幕只覆盖到第 \(minutes) 分钟，后面的内容没有算进去。"
                }
            } else if let local = LocalTranscriptStore.shared.load(id: current.id),
                      !local.lines.isEmpty {
                lines = local.apiLines
                duration = local.durationSeconds
                if local.coverage > 0, local.coverage < 0.8 {
                    subtitleOnlyNotice = "本机转写只覆盖到 \(Self.mmss(local.lastT))，后面没有算进去。"
                }
            } else {
                // 服务端已经解释了为什么拿不到，照抄比另编一句准
                segmentState = .blocked(
                    transcript.reason.isEmpty ? "这条没有可用字幕。" : transcript.reason
                )
                return
            }

            let outcome = try await Segmenter(config: config).segments(
                title: current.title,
                lines: lines,
                durationSeconds: duration
            )
            logSegmentQuality(outcome, id: current.id, duration: duration)
            if let subtitleOnlyNotice { notice = subtitleOnlyNotice }
            let saved = await library.saveSegments(
                id: current.id, segments: outcome.segments, by: config.model
            )
            segmentState = saved ? .idle : .failed("生成成功，但没存上。")
        } catch let failure as SummarizeFailure {
            if case .unparsable(let raw) = failure {
                // 必须留**尾巴**和**长度**，不能只留开头：
                // 截断和格式错的开头长得一模一样，区别全在结尾。
                // 上一版只印 prefix(100)，结果两次报错都没法判断是哪种。
                logs.error("segments.unparsable", "模型没按 JSON 回答", meta: [
                    "id": current.id,
                    "len": String(raw.count),
                    "head": String(raw.prefix(80)),
                    "tail": String(raw.suffix(80)),
                ])
            }
            segmentState = .failed(failure.displayMessage)
        } catch {
            segmentState = .failed(failureMessage(error))
        }
    }

    /// 把「这次分段切得好不好」写成一行日志。
    ///
    /// 四个信号，全都能自动判定，不需要肉眼读一遍段落：
    ///   n       段数，理想 4–9。太少说明模型把内容揉成一坨，太多说明它在按时间均分
    ///   exact   模型给的原始秒数里，恰好命中转写时间点的比例。
    ///           偏低说明它在「自己换算」，那 `snap` 就会把段落到错误的位置
    ///   cover   末段覆盖到总时长的百分之多少，低于 0.8 说明它没读完
    ///   chars   喂进去多少字，接近 12000 就是在顶上下文上限
    private func logSegmentQuality(_ outcome: SegmentOutcome, id: String, duration: Int) {
        let stats = outcome.stats
        let coverage = duration > 0 ? Double(stats.lastT) / Double(duration) : 0
        logs.info("segments.built", "分段完成，段数 \(outcome.segments.count)", meta: [
            "id": id,
            "n": String(outcome.segments.count),
            "raw": String(stats.raw),
            "exact": "\(stats.exact)/\(outcome.segments.count)",
            "snapped": String(stats.snapped),
            "first": String(stats.firstT),
            "last": String(stats.lastT),
            "dur": String(duration),
            "cover": String(format: "%.2f", coverage),
            "blocks": String(stats.blocks),
            "chars": String(stats.chars),
        ])
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

    private func startPlayback(at seconds: Int? = nil) async {
        // 已下载优先：本地文件离线可看，也不必再去要一次地址
        if let local = downloads.localURL(for: item.id) {
            play(local, at: seconds)
            return
        }

        if let player {
            AudioFocus.shared.adopt(player)
            if let seconds {
                _ = await player.seek(
                    to: CMTime(seconds: Double(seconds), preferredTimescale: 600)
                )
            }
            player.play()
            playing = true
            return
        }

        guard let payload = await ensurePlayback(),
              let url = URL(string: payload.url) else { return }
        play(url, at: seconds)
    }

    private func play(_ url: URL, at seconds: Int? = nil) {
        let playerItem = AVPlayerItem(url: url)
        let newPlayer = AVPlayer(playerItem: playerItem)

        // 先把上一次那个掐掉，再认领：否则「返回首页 → 打开另一条」
        // 会出现两个音源同时响（用户报过这个）。
        AudioFocus.shared.adopt(newPlayer)

        player = newPlayer
        playing = true
        notice = nil

        // 起播位置：显式指定的（点分段/书签）优先，
        // 否则接着上次看到的地方——没有这一条，每次点进来都从片头开始。
        let resume = seconds.map(Double.init) ?? PlaybackMemory.shared.position(for: item.id)
        if let resume, resume > 1 {
            Task { _ = await newPlayer.seek(
                to: CMTime(seconds: resume, preferredTimescale: 600)
            ) }
            if seconds == nil {
                notice = "接着上次看到 \(Self.mmss(Int(resume)))。"
            }
        }

        // 每 3 秒记一次进度：进程被杀也能接上，代价只是一次 UserDefaults 写
        if let token = timeObserver { newPlayer.removeTimeObserver(token) }
        timeObserver = newPlayer.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 3, preferredTimescale: 600), queue: .main
        ) { time in
            let current = time.seconds
            guard current.isFinite, current > 0 else { return }
            PlaybackMemory.shared.remember(current, for: item.id)
        }

        let isLocal = url.isFileURL
        logs.info("playback.started", isLocal ? "开始播放（本地文件）" : "开始播放（服务端代理）",
                  meta: ["host": isLocal ? "local" : (url.host ?? "-"),
                         "from": seconds.map(String.init) ?? (resume.map { String(Int($0)) } ?? "0")])

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

    // MARK: - 笔记

    /// 脑图入口。放在摘要卡下面：它是「对摘要的结构化」，
    /// 和摘要属于同一层东西，不该跑到底部去。
    @ViewBuilder
    private var outlineRow: some View {
        if !current.aiSummary.isEmpty || !current.segments.isEmpty {
            Button {
                showOutline = true
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "point.topleft.down.to.point.bottomright.curvepath")
                        .font(.system(size: 11, weight: .semibold))
                    Text("AI 脑图")
                        .font(.cnCaption)
                    Spacer(minLength: 0)
                    Text(current.outline.isEmpty ? "生成" : "\(current.outline.count) 个分支")
                        .font(.cnCaption)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                }
                .foregroundStyle(Color.cnInk3)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    /// 笔记入口。有内容就露三行预览，没有就一行淡入口。
    ///
    /// 预览刻意只放三行：详情页已经有简介和摘要，笔记再展开就把下载按钮推下去了。
    @ViewBuilder
    private var noteRow: some View {
        Button {
            showNote = true
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 5) {
                    Image(systemName: "square.and.pencil")
                        .font(.system(size: 10, weight: .semibold))
                    Text("我的笔记")
                        .font(.cnCaption)
                    Spacer(minLength: 0)
                    Text(current.note.isEmpty ? "写" : "编辑")
                        .font(.cnCaption)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                }
                .foregroundStyle(Color.cnInk3)

                if !current.note.isEmpty {
                    Text(current.note)
                        .font(.cnChip)
                        .foregroundStyle(Color.cnInk2)
                        .lineLimit(3)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(Metric.space3)
            .background(
                Color.cnCard,
                in: RoundedRectangle(cornerRadius: Metric.radiusCard, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Metric.radiusCard, style: .continuous)
                    .strokeBorder(Color.cnHairlineSoft, lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
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
