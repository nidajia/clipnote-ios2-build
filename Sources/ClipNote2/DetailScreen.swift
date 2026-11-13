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
    @EnvironmentObject private var sections: SectionStore
    @EnvironmentObject private var statuses: StatusStore

    @State private var player: AVPlayer?
    @State private var playing = false
    @State private var showFullscreen = false
    /// 图文作品的大图页码。非 nil 就打开全屏看图。
    @State private var galleryIndex: Int?
    /// 背景音乐试听。单独一个 player，不碰视频那个——退出时要一起收声。
    @State private var musicPlayer: AVPlayer?
    @State private var musicPlaying = false
    @State private var musicExportURL: URL?
    @State private var showMusicExport = false
    /// 图文的背景音乐：打开自动播，带进度条、可暂停，能后台播。
    @StateObject private var bgmController = BGMController()
    @State private var showAISettings = false
    @State private var showSegments = false
    @State private var aiState: AIState = .idle
    @State private var segmentState: SegmentState = .idle
    /// 是否已经关注了这条的作者。进入页面时从订阅列表里比对。
    @State private var following = false
    @State private var followBusy = false

    /// 简介展开状态。默认 3 行——长简介会把下面的内容全推下去。
    @State private var summaryExpanded = false
    /// 已经拉下来的楼层（按评论 id 存）。
    ///
    /// 抖音每展开一层都要花钱，所以拉一次就留在内存里，同一次浏览里
    /// 收起再展开不该再扣一次费。
    @State private var liveReplies: [String: [APICommentReply]] = [:]
    @State private var loadingReply = ""

    /// 「更多操作」是否展开（导出、下载都收在里面）。
    @State private var showMore = false
    /// 合集剧集（点开才拉）。
    @State private var season: APISeason?
    @State private var seasonOpen = false

    /// 评论区默认收起：它属于补充信息，不该把详情页撑长。
    @State private var commentsExpanded = false
    /// 「加载更多」实时拉回来的评论（快照只有前 50 条，看全要靠翻页）。
    @State private var liveComments: [APIComment] = []
    @State private var commentsPage = 1
    @State private var commentsSort = "hot"
    @State private var loadingComments = false
    @State private var commentsExhausted = false
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
    @State private var pdfURL: URL?
    @State private var showExport = false
    @State private var showInfographic = false
    @State private var showTranscribe = false
    @State private var showSectionPicker = false
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

    /// 播放器与分段条：首屏第一块。
    ///
    /// 拆这两个块是被编译器逼的：整个 `body` 是一个巨型表达式，
    /// 加到一定规模后 Swift 类型推断直接超时（unable to type-check … in reasonable time）。
    /// 拆开之后每个表达式的类型都好推，编译时间也回来了。
    private var aboveFoldBlock: some View {
        VStack(alignment: .leading, spacing: 0) {
            playerSurface

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

            if !current.segments.isEmpty {
                segmentRail
            }
        }
    }

    /// 标题往下到底部：正文主体。
    private var bodyBlock: some View {
        VStack(alignment: .leading, spacing: Metric.space3) {
                    Text(item.title)
                        .font(.cnTitle)
                        .foregroundStyle(Color.cnInk)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)

                    authorRow

                    followRow

                    if item.kind == .image {
                        imageBGM
                    } else {
                        musicRow
                    }

                    Text(metaLine)
                        .font(.cnMeta)
                        .foregroundStyle(Color.cnInk3)

                    statsRow

                    // 简介紧跟在标题/数据下面。
                    // 用户的直觉是「先看这是什么，再看能干嘛」——之前简介排在
                    // 评论、项目、导出后面，翻到底才看到，等于没有。
                    summaryBlock

                    videoLinkRow

                    sectionRow
                    statusRow

                    // 笔记放在摘要**之前**：首屏能看见。
                    // 原来放在「简介」后面，而那时屏幕已经被播放器、标题、
                    // 作者、AI 摘要卡占满——真机上用户直接问「笔记在哪」。
                    noteRow

                    aiSection

                    outlineRow

                    projectsRow

                    commentsRow

                    exportRow

                    seasonRow

                    if let notice {
                        Text(notice)
                            .font(.cnMeta)
                            .foregroundStyle(Color.cnRed)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    // 导出、下载这些是「偶尔用一次」的动作，不该和内容抢位置。
                    moreSection
                }
                .padding(Metric.pagePad)
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
                aboveFoldBlock

                bodyBlock
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
        // 分区：本地归属，选完立即生效。面板里的「新建」建完直接采用，
        // 不再让用户回来点第二次。
        .sheet(isPresented: $showSectionPicker) {
            NavigationStack {
                SectionPickerSheet(
                    store: sections,
                    current: sections.sectionID(for: current.id)
                ) { id in
                    sections.assign(id, to: [current.id])
                    showSectionPicker = false
                }
            }
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
        // 图文看图：全屏、可横滑。绑到 galleryIndex 而不是 Bool——
        // 从第几张打开是信息，丢了就得从第一张重新翻。
        .fullScreenCover(isPresented: Binding(
            get: { galleryIndex != nil },
            set: { if !$0 { galleryIndex = nil } }
        )) {
            ImageGalleryScreen(item: current, startIndex: galleryIndex ?? 0)
        }
        // 背景音乐导出：先下载成文件，再 ShareLink 分享（可「存储到文件」）
        .sheet(isPresented: $showMusicExport) {
            if let musicExportURL {
                MusicExportSheet(url: musicExportURL) { showMusicExport = false }
                    .presentationDetents([.height(300)])
            }
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
            // 背景音乐也要一起停：试听到一半退出，不该在首页继续响。
            AudioFocus.shared.resign(musicPlayer)
            musicPlaying = false
            bgmController.stop()
            if let timeObserver, let player {
                player.removeTimeObserver(timeObserver)
            }
            timeObserver = nil
        }
        .sheet(isPresented: $showExport) {
            ExportSheet(
                hasSummary: !current.aiSummary.isEmpty,
                onPDF: { exportPDF() },
                onInfographic: { showInfographic = true }
            )
        }
        .sheet(isPresented: Binding(
            get: { pdfURL != nil },
            set: { if !$0 { pdfURL = nil } }
        )) {
            if let pdfURL {
                // 显式 self：`if let pdfURL` 把名字遮住了，
                // 直接写 pdfURL = nil 会被解析成给那个 let 赋值。
                PDFShareSheet(url: pdfURL) { self.pdfURL = nil }
            }
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

    /// 图文的背景音乐：打开就自动播，带进度条、可暂停。
    /// 和视频不同——视频的音轨里有声音，图文没有，看图的配乐得单独放。
    @ViewBuilder
    private var imageBGM: some View {
        if let music = current.music, !music.url.isEmpty {
            BGMBar(controller: bgmController, title: music.title, author: music.author)
                .onAppear {
                    if let url = URL(string: music.url), !bgmController.isPlaying {
                        bgmController.play(url: url)
                    }
                }
        }
    }

    /// 背景音乐。抖音作品才有，第三方可能只给地址、不给歌名。
    /// 有地址就能试听、能导出；歌名是加分项，缺了显示「背景音乐」。
    @ViewBuilder
    private var musicRow: some View {
        if let music = current.music, !music.url.isEmpty {
            HStack(spacing: Metric.space2) {
                Image(systemName: musicPlaying ? "pause.circle.fill" : "play.circle.fill")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Color.cnBrand)

                VStack(alignment: .leading, spacing: 2) {
                    Text(music.title.isEmpty ? "背景音乐" : music.title)
                        .font(.cnChip)
                        .foregroundStyle(Color.cnInk)
                        .lineLimit(1)
                    if !music.author.isEmpty {
                        Text(music.author)
                            .font(.cnCaption)
                            .foregroundStyle(Color.cnInk3)
                            .lineLimit(1)
                    }
                }

                Spacer(minLength: 0)

                Button(musicPlaying ? "暂停" : "试听") {
                    Task { await toggleMusic(music) }
                }
                .font(.cnCaption)
                .foregroundStyle(Color.cnBrand)
                .buttonStyle(.plain)

                Button("导出") {
                    Task { await exportMusic(music) }
                }
                .font(.cnCaption)
                .foregroundStyle(Color.cnBrand)
                .buttonStyle(.plain)
            }
            .padding(Metric.space3)
            .background(
                Color.cnCard,
                in: RoundedRectangle(cornerRadius: Metric.radiusCard, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Metric.radiusCard, style: .continuous)
                    .strokeBorder(Color.cnHairlineSoft, lineWidth: 1)
            )
        }
    }

    private func toggleMusic(_ music: APIMusic) async {
        if musicPlaying {
            musicPlayer?.pause()
            musicPlaying = false
            return
        }
        guard let url = URL(string: music.url) else { return }
        let item = AVPlayerItem(url: url)
        let player = AVPlayer(playerItem: item)
        AudioFocus.shared.adopt(player)
        musicPlayer = player
        player.play()
        musicPlaying = true
    }

    private func exportMusic(_ music: APIMusic) async {
        guard let url = URL(string: music.url) else { return }
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            let base = music.title.isEmpty ? "background-music" : music.title
            let tmp = FileManager.default.temporaryDirectory
                .appendingPathComponent(base + ".mp3")
            try data.write(to: tmp)
            musicExportURL = tmp
            showMusicExport = true
        } catch {
            notice = "音乐下载失败，稍后再试。"
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
        Group {
            if item.kind == .image {
                // 图文作品没有视频流，顶部这块是图片而不是播放器。
                // 以前它走视频分支：显示播放键，点下去服务端把封面（webp）
                // 当视频地址返回，AVPlayerItem 加载它直接闪退。
                ImagePostSurface(item: item) { start in
                    galleryIndex = start
                }
            } else {
                videoSurface
            }
        }
    }

    /// 视频条目那一块：封面 + 播放键，点了才建 AVPlayer。
    private var videoSurface: some View {
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
            Task {
                // 不能 .disabled：灰按钮点下去一声不响，用户只会觉得「坏了」。
                // 要么标上，要么说清楚为什么现在标不了。
                guard player != nil else {
                    notice = "视频还没加载好，等画面出来再标记。"
                    return
                }
                await addBookmarkAtCurrentTime()
            }
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
    /// 导出的常驻入口。
    ///
    /// 之前 PDF 按钮在摘要卡头部、长图也在那里：没有摘要的条目就一个都点不到。
    /// 现在收成一行，和「原视频」「字幕」同层——它属于「这条内容能带走什么」，
    /// 不属于「AI 给了我什么」。
    private var exportRow: some View {
        VStack(spacing: 0) {
            Rectangle()
                .fill(Color.cnHairlineSoft)
                .frame(height: 1)
                .padding(.vertical, 2)

            Button {
                showExport = true
            } label: {
                // 定高 + 居中对齐：图标和文字的行高不一样，
                // 只靠 HStack 默认对齐，文字会贴着分隔线往上飘。
                HStack(spacing: 6) {
                    Image(systemName: "square.and.arrow.up.on.square")
                        .font(.system(size: 11, weight: .semibold))
                        .frame(width: 14)
                    Text("导出")
                        .font(.cnCaption)
                    Spacer(minLength: 0)
                    Text("PDF / 长图")
                        .font(.cnCaption)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .frame(width: 8)
                }
                .foregroundStyle(Color.cnInk3)
                .frame(height: 40)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    /// 导出 PDF。和「长图」并排：一个是给人看的图，一个是给存档/打印的文档。
    private var pdfButton: some View {
        Button {
            exportPDF()
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "doc.richtext")
                    .font(.system(size: 10, weight: .semibold))
                Text("PDF")
                    .font(.cnCaption)
            }
            .foregroundStyle(Color.cnBrand)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Color.cnBrandSoft, in: Capsule())
        }
        .buttonStyle(.plain)
    }

    private func exportPDF() {
        guard let url = PDFExporter.write(current) else {
            notice = "PDF 没写出来，重试一次。"
            logs.error("pdf.failed", "导出 PDF 失败", meta: ["id": current.id])
            return
        }
        pdfURL = url
        logs.info("pdf.built", "导出 PDF", meta: ["id": current.id])
    }

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
        if item.kind == .image {
            // 图文没有音轨，分段/字幕/转写这一整套都没有意义。
            // 留一块空白比留一个点进去必然失败的入口好。
            EmptyView()
        } else if !value.segments.isEmpty {
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

                    Button("转写这条") {
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

                // 已有分段时给一条重跑路径：换模型、或上一版没覆盖全，都靠它。
                // 走服务端重跑（重新下载+转写），不依赖本机有没有转过。
                if !current.segments.isEmpty {
                    Button("重新分段（换模型后重跑）") {
                        Task { await rebuildSegments() }
                    }
                    .font(.cnCaption)
                    .foregroundStyle(Color.cnInk3)
                    .buttonStyle(.plain)
                }

                // 抖音/小红书本来就可能没字幕。等失败一次再给入口等于让用户先撞墙，
                // 所以第一次进来就把这条路摆出来，用弱化的样式，不抢主按钮。
                Button("没有字幕？转写这条") {
                    showTranscribe = true
                }
                .font(.cnCaption)
                .foregroundStyle(Color.cnInk3)
                .buttonStyle(.plain)
            }
        }
    }

    /// 让服务端重跑一条（重新下载 + 转写 + 分段 + 抽项目）。
    ///
    /// 为什么不复用 `generateSegments`：那条路要求本机已经有转写，
    /// 而用户换模型想重跑时，本机往往什么都没有。服务端重跑不依赖本机状态。
    private func rebuildSegments() async {
        guard !library.isOffline, segmentState != .running else { return }
        segmentState = .running
        let ok = await library.rebuildItem(id: current.id)
        segmentState = .idle
        notice = ok
            ? "已交给服务端重跑，大约半分钟到一分钟，之后下拉刷新。"
            : "提交重跑失败，检查网络后再试。"
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
        // 图文没有音轨。真去请求只会拿到「没有字幕」，白等一次还留一条红字。
        guard item.kind != .image else { return }

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
                // 老服务端会把图文封面（webp）当视频地址返回。这个地址一旦
                // 交给 AVPlayerItem，AVKit 会崩而不是报错，所以先挡在这里。
                guard payload.isPlayableMedia else {
                    prepare = .unavailable
                    if !silent { notice = "这是图文作品，没有视频。" }
                    return nil
                }
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
        // 图文作品没有视频流。任何路径（播放键、分段、书签、下载）都不该走到
        // AVPlayer：服务端以前会把封面当流返回，建播放器那一下会闪退。
        guard item.kind != .image else {
            notice = "这是图文作品，没有视频。"
            return
        }

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

    /// 关注作者。
    ///
    /// 为什么放在作者行下面而不是工具栏：订阅这个动作的对象是「人」，
    /// 视觉上就该挨着人。放工具栏会变成「这个视频的某个设置」。
    @ViewBuilder
    private var followRow: some View {
        if !current.displayAuthor.isEmpty {
            Button {
                Task { await toggleFollow() }
            } label: {
                HStack(spacing: 4) {
                    if followBusy {
                        RingSpinner(size: 10, color: .cnBrand)
                    } else {
                        Image(systemName: following ? "checkmark" : "plus")
                            .font(.system(size: 9, weight: .bold))
                    }
                    Text(following ? "已关注，新内容会出现在发现页" : "关注 TA")
                        .font(.cnCaption)
                }
                .foregroundStyle(following ? Color.cnInk3 : Color.cnBrand)
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .background(following ? Color.cnCard3 : Color.cnBrandSoft,
                            in: Capsule())
            }
            .buttonStyle(.plain)
            .disabled(followBusy)
            .task {
                let subs = await library.subscriptions()
                following = subs.contains { $0.name == current.displayAuthor }
            }
        }
    }

    private func toggleFollow() async {
        if following { return }
        followBusy = true
        defer { followBusy = false }
        if let err = await library.addSubscription(itemId: item.id) {
            notice = err
        } else {
            following = true
        }
    }

    /// 简介：默认 3 行，可展开。
    ///
    /// 折叠不是耍花招：抖音的简介动辄几十行（话题标签 + 版权 + 引流），
    /// 全展开会把「笔记」「AI 摘要」推到两屏之外。
    @ViewBuilder
    private var summaryBlock: some View {
        if showsSummary {
            VStack(alignment: .leading, spacing: 5) {
                Text(item.summary)
                    .font(.cnChip)
                    .foregroundStyle(Color.cnInk2)
                    .lineSpacing(5)
                    .lineLimit(summaryExpanded ? nil : 3)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)

                Button {
                    withAnimation(.easeInOut(duration: 0.18)) {
                        summaryExpanded.toggle()
                    }
                } label: {
                    HStack(spacing: 3) {
                        Text(summaryExpanded ? "收起" : "展开全文")
                            .font(.cnCaption)
                        Image(systemName: summaryExpanded ? "chevron.up" : "chevron.down")
                            .font(.system(size: 8, weight: .semibold))
                    }
                    .foregroundStyle(Color.cnBrand)
                }
                .buttonStyle(.plain)
            }
            .padding(Metric.space3)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                Color.cnCard,
                in: RoundedRectangle(cornerRadius: Metric.radiusCard, style: .continuous)
            )
        }
    }

    /// 合集：同一部作品的其它集。
    ///
    /// 只对 B 站有效（`ugc_season`）。抖音没有可靠的合集 ID，
    /// 按标题猜会把不相干的视频并到一起，所以宁可不做。
    @ViewBuilder
    private var seasonRow: some View {
        if !item.seasonId.isEmpty, item.seasonTotal > 1 {
            VStack(alignment: .leading, spacing: Metric.space3) {
                Button {
                    withAnimation(.easeInOut(duration: 0.18)) {
                        seasonOpen.toggle()
                    }
                    if seasonOpen, season == nil {
                        Task { await loadSeason() }
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "rectangle.stack.fill")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Color.cnBrand)
                        Text(item.seasonTitle.isEmpty ? "合集" : item.seasonTitle)
                            .font(.cnChip)
                            .foregroundStyle(Color.cnInk)
                            .lineLimit(1)
                        Text("第 \(item.seasonIndex + 1)/\(item.seasonTotal) 集")
                            .font(.cnCaption)
                            .foregroundStyle(Color.cnInk3)
                        Spacer(minLength: 0)
                        Image(systemName: seasonOpen ? "chevron.up" : "chevron.down")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(Color.cnInk3)
                    }
                }
                .buttonStyle(.plain)

                if seasonOpen {
                    if let season {
                        VStack(alignment: .leading, spacing: 0) {
                            ForEach(season.episodes, id: \.videoId) { ep in
                                seasonEpisodeRow(ep)
                                if ep.videoId != season.episodes.last?.videoId {
                                    Divider().overlay(Color.cnHairlineSoft)
                                }
                            }
                        }
                    } else {
                        HStack(spacing: 6) {
                            RingSpinner(size: 12, color: .cnBrand)
                            Text("正在拉剧集列表…")
                                .font(.cnCaption)
                                .foregroundStyle(Color.cnInk3)
                        }
                    }
                }
            }
            .padding(Metric.space3)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                Color.cnCard,
                in: RoundedRectangle(cornerRadius: Metric.radiusCard, style: .continuous)
            )
        }
    }

    @ViewBuilder
    private func seasonEpisodeRow(_ ep: APISeasonEpisode) -> some View {
        let label = HStack(spacing: Metric.space2) {
            Text("\(ep.created > 0 ? Self.seasonDate(ep.created) : "")")
                .font(.system(size: 9))
                .foregroundStyle(Color.cnInk3)
                .frame(width: 40, alignment: .leading)
            Text(ep.title)
                .font(.cnCaption)
                .foregroundStyle(ep.current ? Color.cnBrand : Color.cnInk)
                .lineLimit(1)
            Spacer(minLength: 0)
            if ep.current {
                Text("当前")
                    .font(.system(size: 9))
                    .foregroundStyle(Color.cnBrand)
            } else if !ep.itemId.isEmpty {
                Image(systemName: "arrow.down.circle.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(Color.cnGreen)
            }
        }
        .padding(.vertical, 7)
        .contentShape(Rectangle())

        if !ep.itemId.isEmpty, !ep.current,
           let target = library.items.first(where: { $0.id == ep.itemId }) {
            NavigationLink {
                DetailScreen(item: target)
            } label: {
                label
            }
            .buttonStyle(.plain)
        } else {
            Button {
                if let url = URL(string: ep.url) {
                    UIApplication.shared.open(url)
                }
            } label: {
                label
            }
            .buttonStyle(.plain)
        }
    }

    /// 「更多操作」：导出、下载。
    ///
    /// 这两块原来直接摊在页面最底部，一屏里堆了导出 CSV / Markdown / 图片、
    /// 下载、重新下载、清缓存……用户的原话是「按钮越来越多，样式有点乱」。
    /// 收进一个折叠区，需要时才展开。
    private var moreSection: some View {
        VStack(spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.18)) {
                    showMore.toggle()
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "ellipsis.circle")
                        .font(.system(size: 12, weight: .semibold))
                    Text("更多操作")
                        .font(.cnCaption)
                    Spacer(minLength: 0)
                    Image(systemName: showMore ? "chevron.up" : "chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                }
                .foregroundStyle(Color.cnInk3)
                .padding(.vertical, 10)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if showMore {
                VStack(spacing: 0) {
                    exportRow
                    downloadSection
                }
                .padding(.top, Metric.space1)
            }
        }
        .padding(.top, Metric.space2)
    }

    private static func seasonDate(_ ts: Int) -> String {
        let f = DateFormatter()
        f.dateFormat = "yy/MM"
        return f.string(from: Date(timeIntervalSince1970: TimeInterval(ts)))
    }

    private func loadSeason() async {
        guard !library.isOffline else { return }
        season = try? await library.season(id: current.id)
    }

    /// 原视频互动数据。只画非零项——抖音没有播放量，硬画一个「播放 0」
    /// 会让人以为是抓取失败。
    @ViewBuilder
    private var statsRow: some View {
        if let stats = current.stats, stats.hasAny {
            HStack(spacing: Metric.space4) {
                if stats.views > 0 {
                    statItem("play.fill", Self.compact(stats.views), "播放")
                }
                if stats.likes > 0 {
                    statItem("hand.thumbsup.fill", Self.compact(stats.likes), "点赞")
                }
                if stats.coins > 0 {
                    statItem("circle.fill", Self.compact(stats.coins), "投币")
                }
                if stats.favorites > 0 {
                    statItem("star.fill", Self.compact(stats.favorites), "收藏")
                }
                if stats.comments > 0 {
                    statItem("bubble.left.fill", Self.compact(stats.comments), "评论")
                }
                Spacer(minLength: 0)
            }
        }
    }

    private func statItem(_ icon: String, _ value: String, _ label: String) -> some View {
        HStack(spacing: 3) {
            Image(systemName: icon)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Color.cnInk3)
            Text(value)
                .font(.cnCaption)
                .foregroundStyle(Color.cnInk2)
        }
        .accessibilityLabel("\(label) \(value)")
    }

    /// 12,345 → 1.2万；1.2 亿 → 1.2亿。中文语境的习惯写法。
    static func compact(_ n: Int) -> String {
        if n >= 100_000_000 {
            return String(format: "%.1f亿", Double(n) / 100_000_000)
        }
        if n >= 10_000 {
            return String(format: "%.1f万", Double(n) / 10_000)
        }
        return "\(n)"
    }

    /// 评论区快照（6.3）。
    ///
    /// 做成独立卡片而不是列表里的一行：评论是「另一类信息」——
    /// 视频讲什么、评论里在吵什么，是两件事。视觉上分开，用户才知道
    /// 这一段不是内容摘要的一部分。
    @ViewBuilder
    private var commentsRow: some View {
        if !current.comments.isEmpty {
            VStack(alignment: .leading, spacing: Metric.space3) {
                HStack(spacing: 6) {
                    Image(systemName: "text.bubble.fill")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color.cnBrand)
                    Text("评论区快照")
                        .font(.cnChip)
                        .foregroundStyle(Color.cnInk)
                    Text("\(displayComments.count) 条 · \(commentsSort == "hot" ? "按热度" : "按时间")")
                        .font(.cnCaption)
                        .foregroundStyle(Color.cnInk3)
                    Spacer(minLength: 0)
                    Button {
                        withAnimation(.easeInOut(duration: 0.18)) {
                            commentsExpanded.toggle()
                        }
                    } label: {
                        HStack(spacing: 3) {
                            Text(commentsExpanded ? "收起" : "展开")
                                .font(.cnCaption)
                            Image(systemName: commentsExpanded ? "chevron.up" : "chevron.down")
                                .font(.system(size: 9, weight: .semibold))
                        }
                        .foregroundStyle(Color.cnBrand)
                    }
                    .buttonStyle(.plain)
                }

                if commentsExpanded {
                    // 排序切换：热度看「大家最在意什么」，最新看「现在在聊什么」。
                    HStack(spacing: Metric.space3) {
                        ForEach([("hot", "按热度"), ("new", "按时间")], id: \.0) { key, label in
                            Button {
                                Task { await loadComments(sort: key, reset: true) }
                            } label: {
                                Text(label)
                                    .font(.cnCaption)
                                    .foregroundStyle(commentsSort == key ? Color.cnBrand : Color.cnInk3)
                            }
                            .buttonStyle(.plain)
                        }
                        Spacer(minLength: 0)
                    }

                    VStack(alignment: .leading, spacing: Metric.space3) {
                        ForEach(Array(displayComments.enumerated()), id: \.offset) { index, one in
                            if index > 0 {
                                Divider().overlay(Color.cnHairlineSoft)
                            }
                            commentCell(one)
                        }
                    }

                    if !commentsExhausted {
                        Button {
                            Task { await loadComments(sort: commentsSort, reset: false) }
                        } label: {
                            HStack(spacing: 5) {
                                if loadingComments {
                                    RingSpinner(size: 12, color: .cnBrand)
                                }
                                Text(loadingComments ? "正在加载…" : "加载更多")
                                    .font(.cnCaption)
                            }
                            .foregroundStyle(Color.cnBrand)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                        }
                        .buttonStyle(.plain)
                        .disabled(loadingComments)
                    }
                } else {
                    // 收起时给一句「里面有什么」，否则用户不知道值不值得展开。
                    Text("视频被删之后，这里还能看到当时大家在说什么。")
                        .font(.cnCaption)
                        .foregroundStyle(Color.cnInk3)
                }
            }
            .padding(Metric.space3)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                Color.cnCard,
                in: RoundedRectangle(cornerRadius: Metric.radiusCard, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Metric.radiusCard, style: .continuous)
                    .strokeBorder(Color.cnHairline, lineWidth: 0.5)
            )
        }
    }

    /// 翻过页就用翻页结果，否则用快照里的（离线也能看）。
    private var displayComments: [APIComment] {
        liveComments.isEmpty ? current.comments : liveComments
    }

    /// 拉一页评论。`reset` 为真时从第 1 页重来（切排序时用）。
    private func loadComments(sort: String, reset: Bool) async {
        guard !loadingComments, !library.isOffline else { return }
        loadingComments = true
        defer { loadingComments = false }
        if reset {
            commentsSort = sort
            liveComments = []
            commentsPage = 1
            commentsExhausted = false
        }
        let next = liveComments.isEmpty ? 1 : commentsPage + 1
        do {
            let page = try await library.comments(id: current.id, page: next, sort: sort)
            if next == 1 {
                liveComments = page.comments
            } else {
                liveComments.append(contentsOf: page.comments)
            }
            commentsPage = next
            commentsExhausted = !page.hasMore || page.comments.isEmpty
        } catch {
            commentsExhausted = true
        }
    }

    /// 一条评论（抖音/贴吧那种版式）。
    ///
    /// 左头像、中间昵称+正文+楼层、右侧点赞——这是用户熟悉的肌肉记忆。
    /// 之前把作者和正文挤在同一个 `VStack` 里，看着像一坨文字，分不出谁在说话。
    private func loadReplies(_ one: APIComment) async {
        if loadingReply == one.cid { return }
        loadingReply = one.cid
        defer { loadingReply = "" }
        let rows = await library.replies(id: current.id, cid: one.cid)
        if !rows.isEmpty {
            liveReplies[one.cid] = rows
        } else {
            notice = one.replyCount > 0
                ? "这层回复拉不到，可能已经删了。"
                : "这层还没有回复。"
        }
    }

    private func commentCell(_ one: APIComment) -> some View {
        HStack(alignment: .top, spacing: 10) {
            avatar(one.avatar, size: 34)

            VStack(alignment: .leading, spacing: 5) {
                Text(one.author)
                    .font(.cnCaption)
                    .foregroundStyle(Color.cnInk3)
                    .lineLimit(1)

                Text(one.text)
                    .font(.cnMeta)
                    .foregroundStyle(Color.cnInk)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)

                // 表情：B 站正文里写的是 `[吃瓜]`，服务端把对应图片拆出来了。
                // 放在正文下面一行而不是内联混排——异步图和文本的流式换行
                // 容易错行，分开更稳，用户照样能看见那个表情。
                if !one.segments.filter({ $0.type == "emote" }).isEmpty {
                    HStack(spacing: 4) {
                        ForEach(one.segments.filter { $0.type == "emote" }.map(\.value),
                                id: \.self) { src in
                            AsyncImage(url: URL(string: src)) { phase in
                                if case .success(let img) = phase {
                                    img.resizable().scaledToFit()
                                } else {
                                    Color.clear
                                }
                            }
                            .frame(width: 22, height: 22)
                        }
                    }
                }

                if !one.pictures.isEmpty {
                    HStack(spacing: 6) {
                        ForEach(one.pictures, id: \.self) { src in
                            AsyncImage(url: URL(string: src)) { phase in
                                if case .success(let image) = phase {
                                    image.resizable().scaledToFill()
                                        .frame(width: 88, height: 88)
                                        .clipShape(RoundedRectangle(cornerRadius: 8,
                                                                    style: .continuous))
                                } else {
                                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                                        .fill(Color.cnCard3)
                                        .frame(width: 88, height: 88)
                                }
                            }
                        }
                    }
                    .padding(.top, 2)
                }

                // 楼层：左侧一条竖线把「谁在回谁」串起来。
                if !one.replies.isEmpty || one.replyCount > 0 {
                    let shown = liveReplies[one.cid] ?? one.replies
                    VStack(alignment: .leading, spacing: 7) {
                        ForEach(Array(shown.enumerated()), id: \.offset) { _, reply in
                            HStack(alignment: .top, spacing: 6) {
                                avatar(reply.avatar, size: 20)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(reply.author)
                                        .font(.cnCaption)
                                        .foregroundStyle(Color.cnInk3)
                                    Text(reply.text)
                                        .font(.cnCaption)
                                        .foregroundStyle(Color.cnInk2)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                        }
                        // 抖音的楼层是**按需买**的（展开一层 $0.002），
                        // 所以默认只显示「共 N 条回复」，点了才去拉。
                        // B 站的楼层是快照里带的（免费），直接显示。
                        if one.replyCount > shown.count, !one.cid.isEmpty,
                           shown.isEmpty || one.replyCount > shown.count {
                            Button {
                                Task { await loadReplies(one) }
                            } label: {
                                HStack(spacing: 3) {
                                    if loadingReply == one.cid {
                                        RingSpinner(size: 9, color: .cnBrand)
                                    }
                                    Text(shown.isEmpty
                                         ? "展开 \(one.replyCount) 条回复"
                                         : "还有 \(one.replyCount - shown.count) 条回复")
                                        .font(.cnCaption)
                                }
                                .foregroundStyle(Color.cnBrand)
                            }
                            .buttonStyle(.plain)
                            .disabled(loadingReply == one.cid)
                        } else if one.replyCount > shown.count, one.cid.isEmpty {
                            // 老数据的评论没有平台 id，拉不到更多楼层。
                            // 与其给一个点了必然失败的按钮，不如老实说数字。
                            Text("共 \(one.replyCount) 条回复")
                                .font(.cnCaption)
                                .foregroundStyle(Color.cnInk3)
                        }
                    }
                    .padding(.leading, 10)
                    .overlay(alignment: .leading) {
                        Capsule()
                            .fill(Color.cnHairline)
                            .frame(width: 2)
                    }
                    .padding(.top, 2)
                }
            }

            Spacer(minLength: 0)

            VStack(spacing: 2) {
                Image(systemName: "hand.thumbsup")
                    .font(.system(size: 12, weight: .regular))
                Text(one.likes > 0 ? Self.compact(one.likes) : "赞")
                    .font(.system(size: 10))
            }
            .foregroundStyle(Color.cnInk3)
        }
    }

    /// 圆头像。抓不到就画一个灰底人形，不要留空洞。
    private func avatar(_ src: String, size: CGFloat) -> some View {
        AsyncImage(url: URL(string: src)) { phase in
            if case .success(let image) = phase {
                image.resizable().scaledToFill()
            } else {
                Circle()
                    .fill(Color.cnCard3)
                    .overlay(
                        Image(systemName: "person.fill")
                            .font(.system(size: size * 0.45))
                            .foregroundStyle(Color.cnInk3)
                    )
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
    }

    /// 视频里提到的项目 / 工具 / 网站。
    ///
    /// 有 `url` 的直接可点；没有的只显示名字——模型不确定时不会编链接，
    /// 所以「名字没有链接」是正常状态，不该看起来像坏了。
    @ViewBuilder
    private var projectsRow: some View {
        if !current.projects.isEmpty {
            VStack(alignment: .leading, spacing: Metric.space2) {
                Text("视频里提到的")
                    .font(.cnCaption)
                    .foregroundStyle(Color.cnInk3)

                ForEach(Array(current.projects.enumerated()), id: \.offset) { _, one in
                    if let link = URL(string: one.url), !one.url.isEmpty {
                        Link(destination: link) {
                            projectLabel(one, tappable: true)
                        }
                    } else {
                        projectLabel(one, tappable: false)
                    }
                }
            }
        }
    }

    private func projectLabel(_ one: APIProject, tappable: Bool) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: tappable ? "link" : "smallcircle.filled.circle")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(tappable ? Color.cnBrand : Color.cnInk3)
                .frame(width: 14, height: 18, alignment: .center)

            VStack(alignment: .leading, spacing: 2) {
                Text(one.name)
                    .font(.cnChip)
                    .foregroundStyle(tappable ? Color.cnBrand : Color.cnInk)
                    .lineLimit(1)
                if !one.note.isEmpty {
                    Text(one.note)
                        .font(.cnCaption)
                        .foregroundStyle(Color.cnInk3)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
    }

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
    /// 「我为什么存它」。位置放在作者链接之后、笔记之前：
    /// 这两行都是「我给的属性」，连着读才顺；放进摘要卡会被当成 AI 产物。
    /// 状态用菜单而不是面板：只有四个选项，弹一层 sheet 不值得。
    private var statusRow: some View {
        let now = statuses.status(for: current.id)
        return Menu {
            Button {
                statuses.set(nil, for: [current.id])
            } label: {
                Label("清除标记", systemImage: "xmark.circle")
            }
            ForEach(ItemStatus.allCases) { item in
                Button {
                    statuses.set(item, for: [current.id])
                } label: {
                    Label(item.title, systemImage: item.symbol)
                }
            }
        } label: {
            HStack(spacing: Metric.space2) {
                Image(systemName: now?.symbol ?? "circle.dashed")
                    .font(.system(size: 12, weight: .regular))
                    .foregroundStyle(now == nil ? Color.cnInk3 : Color.cnBrand)
                    .frame(width: 18)
                Text("状态")
                    .font(.cnChip)
                    .foregroundStyle(Color.cnInk3)
                if let now {
                    Text(now.title)
                        .font(.cnChip)
                        .foregroundStyle(Color.cnInk)
                } else {
                    Text("未标记 · 点这里设")
                        .font(.cnChip)
                        .foregroundStyle(Color.cnInk3)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Color.cnInk3)
            }
            .contentShape(Rectangle())
            .padding(.vertical, 6)
        }
        .buttonStyle(.plain)
    }

    private var sectionRow: some View {
        let assigned = sections.section(for: current.id)
        return Button {
            showSectionPicker = true
        } label: {
            HStack(spacing: Metric.space2) {
                Image(systemName: assigned?.symbol ?? "square.grid.2x2")
                    .font(.system(size: 12, weight: .regular))
                    .foregroundStyle(assigned == nil ? Color.cnInk3 : Color.cnBrand)
                    .frame(width: 18)
                Text("分区")
                    .font(.cnChip)
                    .foregroundStyle(Color.cnInk3)
                if let assigned {
                    Text(assigned.name)
                        .font(.cnChip)
                        .foregroundStyle(Color.cnInk)
                } else {
                    Text("未分区 · 点这里归类")
                        .font(.cnChip)
                        .foregroundStyle(Color.cnInk3)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Color.cnInk3)
            }
            .contentShape(Rectangle())
            .padding(.vertical, 6)
        }
        .buttonStyle(.plain)
    }

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
                Text(item.kind == .image
                     ? "这是图文作品，没有视频可下载。点上面的图可以看大图。"
                     : "这条内容以文字为主，没有可下载的视频。")
                    .font(.cnMeta)
                    .foregroundStyle(Color.cnInk3)
                    .fixedSize(horizontal: false, vertical: true)

            } else if downloads.isDownloaded(item.id) {
                // 0MB 的假记录：当时下载到的是 CDN 的错误页，被当成了成功。
                // 这种条目看不了也删不掉，必须给一条明确的「重新下载」出口。
                if downloads.byteCount(for: item.id) < 64 * 1024 {
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 13, weight: .semibold))
                        Text("下载的文件不完整（\(sizeText)），需要重新下载")
                            .font(.cnMeta)
                    }
                    .foregroundStyle(Color.cnRed)

                    PrimaryButton(title: "重新下载") {
                        Task { await redownload() }
                    }
                } else {
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

    /// 把不完整的下载清掉再重来一次。地址要重新取——旧地址早过期了。
    private func redownload() async {
        downloads.removeLocalFile(item.id)
        prepare = .idle
        await startDownload()
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
