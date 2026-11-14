import SwiftUI

/// 仅用于 CI 截图：通过启动参数直接进入指定状态。
///
/// 正常启动走 `RootView`，不经过这里，也不碰这里的样本库。
/// 之所以要这个入口，是因为 `ImageRenderer` 画不出 `List` / `TabView`
/// （UIKit 背书的容器会整张渲染成系统「不可用」占位符），
/// 只能真的把 App 启动起来再截屏。
///
/// 数据来自 bundle 里的 `library-sample.json`，走的是**与线上相同的解码器**。
/// 于是每张截图都在同时证明两件事：解码没错，渲染没错。而且不依赖网络，
/// 同一份代码任何时候截出来都一样——这是截图能当证据的前提。
struct SnapshotRoot: View {
    private let state: String
    private let appearance: ColorScheme?
    private let detailItem: Item?

    @State private var tab: Int
    @StateObject private var downloads: DownloadStore
    @StateObject private var library: LibraryStore
    @StateObject private var logs: LogStore
    @StateObject private var sections: SectionStore
    @StateObject private var statuses: StatusStore

    init(state: String, appearance: ColorScheme?) {
        self.state = state
        self.appearance = appearance
        _tab = State(initialValue: state == "me" ? 2
                     : (state.hasPrefix("discover") ? 1 : 0))

        // 每次启动用独立的临时目录：否则上一次截图种下的「已下载」
        // 会留在 Documents 里，把这一次的「未下载」状态带脏。
        let sandbox = FileManager.default.temporaryDirectory
            .appendingPathComponent("snapshot-\(UUID().uuidString)", isDirectory: true)
        // 截图用独立的 LogStore：不写真实日志、不上报，避免把假事件灌进服务端
        let logStore = LogStore(directory: sandbox, uploader: nil)
        // 「我」和日志页需要内容可看，否则永远是空态
        if state == "logs" || state == "me" {
            logStore.info("app.launch", "启动", meta: ["version": AppVersion.text])
            logStore.info("library.loaded", "同步完成 8 条",
                          meta: ["count": "8", "version": "lv_1793265909_1", "ms": "412"])
            logStore.info("import.created", "导入成功", meta: ["created": "1", "ms": "1913"])
            logStore.warn("playback.unavailable", "该内容没有视频流",
                          meta: ["id": "seed0000000005"])
            logStore.error("network.failed", "连不上服务端。请求超时。",
                           meta: ["path": "/api/v2/library", "kind": "transport", "ms": "20013"])
        }
        let store = DownloadStore(directory: sandbox, log: logStore)

        // 传 sandbox 作为缓存目录：不让某次真实运行留下的缓存混进截图，
        // 每张图的数据只来自 bundle 里的 fixture。
        let lib = LibraryStore(client: nil, cacheDirectory: sandbox)
        // 注意顺序：**只有需要数据的状态才加载**。
        // 之前先无条件 loadFixture 再切状态，结果 loading / failed 两张图都带着
        // 一屏数据，和列表图长得一模一样——截图「拍到了」，但拍的是别的东西。
        switch state {
        case "empty":
            lib.applyEmpty()
        case "failed":
            lib.markFailed("服务端返回的不是数据。多半是线上版本还没更新。")
        case "loading":
            break // 保持 idle，首页即加载态
        default:
            if let data = Item.sampleData {
                try? lib.loadFixture(data)
            }
        }

        var detail: Item?
        if state.hasPrefix("detail") {
            detail = state == "detail-note"
                ? lib.items.first { $0.kind == .note }
                : lib.items.first
            if let id = detail?.id {
                switch state {
                case "detail-downloading": store.seedDownloading(id, value: 0.62)
                case "detail-downloaded": store.seedDownloaded(id)
                default: break
                }
            }
        }
        self.detailItem = detail

        // 摘要截图：直接塞一份示例，不联网、不调模型（截图里不该有真实调用）
        if state == "detail-summary", let id = detail?.id {
            lib.seedSummary(
                id: id,
                summary: "这条片子讨论的是：现在的 AI 热潮与 2000 年互联网泡沫，究竟哪里像、哪里不一样。"
                    + "结论不是「一定会崩」，而是估值与收入之间的缺口比当年更难解释。",
                keyPoints: [
                    "估值跑在收入前面，且集中在少数几家公司",
                    "与 2000 年不同：这次的基础设施是真实在用的",
                    "资本开支的回收周期比市场预期更长",
                ],
                labels: ["AI", "投资", "互联网史"]
            )
        }

        // 分段截图：摘要 + 分段同时给，验的是「摘要卡里怎么塞下分段」
        if state == "detail-segments", let id = detail?.id {
            lib.seedSummary(
                id: id,
                summary: "这条片子讨论的是：现在的 AI 热潮与 2000 年互联网泡沫，究竟哪里像、哪里不一样。"
                    + "结论不是「一定会崩」，而是估值与收入之间的缺口比当年更难解释。",
                keyPoints: [
                    "估值跑在收入前面，且集中在少数几家公司",
                    "与 2000 年不同：这次的基础设施是真实在用的",
                ],
                labels: ["AI", "投资", "互联网史"]
            )
            lib.seedSegments(id: id, segments: SnapshotRoot.sampleSegments)
        }

        // 分段页单独截图：它验的是「9 段排下来会不会挤在一起」
        if state == "segments", let id = lib.items.first?.id {
            lib.seedSegments(id: id, segments: SnapshotRoot.sampleSegments)
        }

        // 信息图：摘要 + 9 段一起给。9 段是实测的段数上限一带，
        // 用它才知道长图会到多高、分段区会不会挤成一团。
        if state == "infographic", let id = lib.items.first?.id {
            lib.seedSummary(
                id: id,
                summary: "这条片子讨论的是：现在的 AI 热潮与 2000 年互联网泡沫，究竟哪里像、哪里不一样。"
                    + "结论不是「一定会崩」，而是估值与收入之间的缺口比当年更难解释。",
                keyPoints: [
                    "估值跑在收入前面，且集中在少数几家公司",
                    "与 2000 年不同：这次的基础设施是真实在用的",
                    "资本开支的回收周期比市场预期更长",
                ],
                labels: ["AI", "投资", "互联网史"]
            )
            lib.seedSegments(id: id, segments: SnapshotRoot.sampleSegments)
            lib.seedAuthor(id: id, author: "幽州-节度使", authorId: "", videoId: "",
                           note: "")
        }

        // 笔记筛选：给前两条写上笔记，并让其中一条是「笔记条目」本身。
        // 这样截图能同时验证三件事：笔记筛选只收有内容的、行内带修改时间、
        // 点进去是编辑器而不是视频页。
        if state == "home-notes" {
            let ids = lib.items.map(\.id)
            if ids.count > 1 {
                lib.seedNote(id: ids[0], note: "# 存储架构评审\n\n## 背景\n\n三组对照实验可以直接套到下季度容量评估。")
                lib.seedNote(id: ids[1], note: "## 要点\n\n- 利息覆盖倍数在下降\n- 资本开支前置")
            }
        }

        // 作者行：详情页截图要能看到头像、名字、备注入口
        if state.hasPrefix("detail"), let id = detail?.id {
            // 故意把 author/videoId 留空，模拟线上那 4 条存量数据：
            // 只有 metaLine 里的作者名、没有 bvid。截图要验的正是这条兜底路径。
            lib.seedAuthor(id: id, author: "", authorId: "", videoId: "",
                           note: "讲存储很扎实，适合看架构")
            lib.seedNote(id: id, note: "他的三组对照实验部分可以直接套到我们下季度的容量评估里。\n另外开头的那个提问方式值得学。")
        }

        // 评论区截图：种几条带楼层、表情、时间、点赞的评论，验「评论区快照」区块
        // 能渲染（不再只有空壳）。评论数刻意超过 20 条，顺带验「加载更多」不会被 20 条覆盖。
        if state == "detail", let id = detail?.id {
            lib.seedComments(id: id, comments: SnapshotRoot.sampleComments)
        }

        // 发现页截图：种一份带分类、热榜、合集的 feed。
        // 验三件事：筛选栏始终在（切「合集」也回得去）、热榜能渲染、合集入口可见。
        if state.hasPrefix("discover") {
            lib.seedDiscoverFeed(SnapshotRoot.sampleDiscoverFeed)
        }

        // 脑图：塞一棵三层树。注意分支名刻意都不带时间词——
        // 截图同时也在验提示词的目标形态（按概念归类，不是按时间顺序）。
        if state == "outline", let id = lib.items.first?.id {
            lib.seedSummary(
                id: id,
                summary: "这条片子讨论的是：现在的 AI 热潮与 2000 年互联网泡沫，究竟哪里像、哪里不一样。",
                keyPoints: ["估值跑在收入前面"],
                labels: ["AI", "投资"]
            )
            lib.seedOutline(id: id, outline: SnapshotRoot.sampleOutline)
        }

        // 书签：分段和旗子同时给，验的是「两种东西能不能一眼分开」
        if state == "detail-bookmarks", let id = detail?.id {
            lib.seedSegments(id: id, segments: SnapshotRoot.sampleSegments)
            lib.seedBookmarks(id: id, bookmarks: SnapshotRoot.sampleBookmarks)
        }

        // 标签页截图：要一份像真跑过几轮的分布，不是「每个标签 1 条」
        if state == "tags" {
            for (index, labels) in SnapshotRoot.sampleTagPlan where index < lib.items.count {
                lib.seedLabels(id: lib.items[index].id, labels: labels)
            }
        }

        _downloads = StateObject(wrappedValue: store)
        _library = StateObject(wrappedValue: lib)
        _logs = StateObject(wrappedValue: logStore)

        // 分区：给前几条归类。故意留几条没归——全归好了就看不出「未分区」
        // 那一条筛选，而那正是用户第一次用时会看到的形态。
        //
        // 注意 `list` 而不是 `home-list`：截图的**文件名**叫 home-list，
        // 但传给 App 的场景名是 `list`（见 screenshot.sh）。写错这一处不会报错，
        // 只会得到一张「分区一个都没分」的图，看起来像功能没生效——已踩。
        let sectionStore = SectionStore(directory: sandbox, log: logStore)
        if state == "list" || state == "home-list" || state == "home-section"
            || state.hasPrefix("detail") || state == "section-picker" {
            let ids = lib.items.map(\.id)
            var plan: [String: String] = [:]
            for (index, id) in ["study", "study", "info", "fun", "know"].enumerated()
            where index < ids.count {
                plan[ids[index]] = id
            }
            sectionStore.seed(assignment: plan)
        }
        _sections = StateObject(wrappedValue: sectionStore)
        // 截图里的状态标记：给前两条，别全标——全标看不出「没标过不画点」
        let statusStore = StatusStore(directory: sandbox, log: logStore)
        if state == "list" || state == "home-section" || state == "home-notes" {
            let ids = lib.items.map(\.id)
            if ids.count > 2 {
                statusStore.set(.doing, for: [ids[0]])
                statusStore.set(.done, for: [ids[1]])
            }
        }
        _statuses = StateObject(wrappedValue: statusStore)
    }

    var body: some View {
        Group {
            if state == "logs" {
                // 日志页在「我」里，截图没法点进去，直接作为根呈现
                NavigationStack { LogScreen() }
            } else if state == "trash" {
                NavigationStack { TrashScreen(previewItems: previewTrash) }
            } else if state == "ai-settings" {
                NavigationStack { AISettingsScreen() }
            } else if state == "ai-models" {
                // 列表是从服务商读来的，截图里用固定样本模拟「已读到」
                NavigationStack {
                    ModelPickerSheet(
                        base: AIProviderPreset.siliconflow.base,
                        key: "sk-preview",
                        selected: .constant("Qwen/Qwen2.5-7B-Instruct"),
                        initialModels: SnapshotRoot.sampleModels
                    )
                }
            } else if state == "note-new" {
                // 新建笔记的默认形态：大标题 + 三个小标题，光标在文末。
                // 这张图要能证明「点进来就有结构」，而不是一张白纸。
                NavigationStack {
                    // 这里**不**自动聚焦：模拟器第一次弹键盘会盖一层
                    // 「滑动输入」教学弹窗，把整块编辑区挡住，图就白拍了。
                    // 真实路径是 `beginAtEnd: true`（见 HomeScreen.createNote），
                    // 光标落位由 check-form 的 __focusEnd 与真机 N10 覆盖。
                    NoteScreen(item: SnapshotRoot.templateNote)
                }
            } else if state == "note-probe" {
                // 排障页：WebView 能不能执行内联 JS
                NavigationStack { ProbeScreen() }
            } else if state == "note-editor" {
                // 笔记编辑器：P2 的核心，之前从没被截图验证过。
                // 直接作为根渲染，绕过详情页导航，减少变量。
                if let item = library.items.first {
                    NavigationStack { NoteScreen(item: item) }
                } else {
                    Color.cnBg
                }
            } else if state == "outline" {
                if let item = library.items.first {
                    NavigationStack { OutlineScreen(item: item) }
                } else {
                    Color.cnBg
                }
            } else if state == "segments" {
                if let item = library.items.first {
                    NavigationStack { SegmentsScreen(item: item) }
                } else {
                    Color.cnBg
                }
            } else if state == "infographic" {
                // 长图页是模态呈现的，截图没法点开，直接作为根呈现。
                // 它验的是两件事：首屏那截排版对不对，以及渲染有没有真的产出图像
                // （`.task` 里跑的就是线上那条渲染路径）。
                if let item = library.items.first {
                    InfographicSheet(item: item)
                } else {
                    Color.cnBg
                }
            } else if state.hasPrefix("transcribe") {
                // 本机转写面板同理：它是 sheet，只能作为根呈现。
                // 两态各一张——「转写中」验进度区，「完成」验行列表和覆盖率提示。
                // 注意这两种都是**预览态**：模拟器上 supportsOnDeviceRecognition
                // 一定是 false，真跑只会停在「这台设备暂时不行」，拍不到这两种。
                if let item = library.items.first {
                    TranscribeSheet(
                        item: item,
                        preview: transcribePreview(item),
                        // 转写中那一张要给一个非零计时，否则「右边那个计时器」
                        // 在截图里根本不存在，等于没验。
                        previewElapsed: state == "transcribe-running" ? 134
                            : (state == "transcribe-cloud" ? 42 : 0),
                        previewEngine: state == "transcribe-cloud" ? .cloud : nil
                    )
                } else {
                    Color.cnBg
                }
            } else if state == "tags" {
                NavigationStack { TagsScreen() }
            } else if state == "section-picker" {
                // 选择器是 sheet，只能作为根呈现。分区归属已在 init 里种好，
                // 所以这张图能看出「当前在哪一类」的勾选态。
                NavigationStack {
                    SectionPickerSheet(store: sections, current: "study") { _ in }
                }
            } else if state.hasPrefix("onboarding") {
                // 引导是首启才出现的，截图靠 previewPhase 直接停到某一帧。
                // 真机上这条路径由 RootView 的 AppStorage 判定，与这里同一套视图。
                OnboardingFlow(previewPhase: onboardingPhase)
            } else if state == "player-landscape" {
                // 直接作为根呈现，不走 fullScreenCover：截图不关心转场动画，
                // 只关心这一页在横屏尺寸下排得对不对。方向由 PlayerScreen
                // 自己的 onAppear 去要，和真机走的是同一段代码。
                if let item = library.items.first {
                    PlayerScreen(item: item, player: nil)
                } else {
                    Color.black
                }
            } else {
                tabs
            }
        }
        .tint(Color.cnBrand)
        .preferredColorScheme(appearance)
        .environmentObject(downloads)
        .environmentObject(library)
        .environmentObject(logs)
        .environmentObject(sections)
        .environmentObject(statuses)
    }

    private var tabs: some View {
        TabView(selection: $tab) {
            NavigationStack {
                HomeScreen(
                    initialSelection: detailItem,
                    detailPrepare: detailPrepare,
                    showsImport: state == "import",
                    // 多选那张图要能证明「选择」按钮和底部操作条真的在，
                    // 光靠代码读一遍不算数——上一轮就是这么漏掉的。
                    previewSelecting: state == "home-selecting",
                    // 分区筛选态：`@State` 从外部设不了，只能从 init 进来
                    previewFilter: state == "home-section" ? .section("study")
                        : (state == "home-notes" ? .note : nil)
                )
            }
            .tabItem { Label("首页", systemImage: "house.fill") }
            .tag(0)

            NavigationStack {
                DiscoverScreen(initialCategory: state == "discover-collections" ? "合集" : nil)
            }
            .tabItem { Label("发现", systemImage: "sparkles") }
            .tag(1)

            NavigationStack {
                MeScreen()
            }
            .tabItem { Label("我", systemImage: "person.fill") }
            .tag(2)
        }
    }

    /// 新建笔记时的条目形态。用真模板生成，不手抄一份——
    /// 否则改了模板，这张截图会继续展示旧结构。
    static var templateNote: Item {
        Item(
            id: "note-preview",
            kind: .note,
            title: "周二复盘",
            metaLine: "笔记",
            durationText: "",
            note: NoteTemplate.body(title: "周二复盘"),
            createdAt: Date(),
            updatedAt: Date()
        )
    }

    /// 引导截图停在的那一帧。`.welcome` 用 nil 表示（init 默认值）。
    private var onboardingPhase: SyncPhase? {
        switch state {
        case "onboarding-syncing":
            return .syncing(.connecting)
        case "onboarding-done":
            // 条数取真实样本的条数，不写死一个数字——
            // 否则改了 fixture，截图会开始说谎
            return .done(count: library.items.count, milliseconds: 620)
        case "onboarding-failed":
            return .failed(message: "连不上服务端。请求超时。", step: .connecting)
        default:
            return nil
        }
    }

    /// 回收站截图用的两条已删条目
    private var previewTrash: [APILibraryItem] {
        guard let data = Item.sampleData,
              let lib = try? JSONDecoder().decode(APILibrary.self, from: data) else { return [] }
        return lib.items.prefix(2).enumerated().map { index, item in
            var copy = item
            copy.deletedAt = 1_793_430_625_000 - index * 86_400_000
            return copy
        }
    }

    /// 只给 `detail-ready` 用：模拟「已经取到播放地址」，
    /// 好让按钮下面那行「720P · 约 124 MB」有截图可对照。
    private var detailPrepare: DetailScreen.PrepareState? {
        guard state == "detail-ready" else { return nil }
        return .ready(APIPlaybackPayload(
            url: "https://clipnote.app.workbuddy.host/proxy?u=sample.mp4",
            mimeType: "video/mp4",
            quality: "720P",
            bytes: 130_257_119,
            expiresAt: 0
        ))
    }

    /// 转写面板要停在哪一态。文案照真跑出来的样子写：有停顿、有口语。
    ///
    /// 四张「不正常」的图各有各的必要：真机上这四条分支都验不到
    /// （模拟器上 `supportsOnDeviceRecognition` 恒为 false，权限/卡死/失败
    /// 都不会自然出现），只能靠 preview 把它们摆出来，让文案被看见一次。
    private func transcribePreview(_ item: Item) -> TranscribeSheet.Stage {
        switch state {
        case "transcribe-cloud":
            // 云端那条路：进度按「第 n/N 段」，不是百分比。
            return .transcribing(tail: "", chars: 1240)
        case "transcribe-running":
            return .transcribing(
                tail: "…所以你看这个缺口，它不是一年形成的，是一轮一轮融资把它推上去的",
                chars: 218
            )
        case "transcribe-blocked":
            // 模拟器真实走到的就是这一支，所以文案要和系统给的一致
            return .blocked(TranscribeSupport.needsAssets.message)
        case "transcribe-permission":
            return .needsPermission
        case "transcribe-failed":
            return .failed("识别完了但没有文字。可能是纯音乐、人声太轻，或者音轨是空的。")
        case "transcribe-stalled":
            // 03:32：既过了 45 秒的静默阈值，又没到 45 分钟的硬顶，
            // 显示的是「卡住」那条文案而不是「超时」那条。
            return .stalled(seconds: 212, phase: .transcribing)
        default:
            return .done(LocalTranscript(
                itemId: item.id,
                lines: SnapshotRoot.sampleTranscriptLines,
                // 360 秒：样本最后一行在 336，覆盖率 0.93，
                // 于是「只覆盖到…」那句不会出现——这才是正常跑完的样子。
                // 覆盖率偏低的提示由单测覆盖，不在截图上占一张。
                durationSeconds: 360,
                createdAt: Date(timeIntervalSince1970: 1_793_400_000),
                locale: "zh-CN"
            ))
        }
    }

    /// 本机转写的样本。刻意保留口语和停顿（「对」「就是」），
    /// 因为截图要验的是「一行念完是一句话」，不是漂亮的书面语。
    static let sampleTranscriptLines: [TranscriptLine] = [
        TranscriptLine(t: 0, text: "这条片子我想聊的不是涨跌，而是一个更基础的问题。"),
        TranscriptLine(t: 14, text: "就是现在这些公司的估值，和它们真正收到的钱之间，差了多少。"),
        TranscriptLine(t: 41, text: "我把两条线摆在一起看，缺口是一眼可见的，而且它已经连续扩大了六个季度。"),
        TranscriptLine(t: 78, text: "有人说这和两千年那次一模一样。我觉得像的地方确实很多，比如说叙事驱动定价。"),
        TranscriptLine(t: 132, text: "但不一样的地方也很硬：这次的基础设施是真的在被消耗掉的。"),
        TranscriptLine(t: 178, text: "算力和电费都是有账可查的支出，这部分收入对得上，不是纯粹的想象。"),
        TranscriptLine(t: 245, text: "真正容易忽略的是折旧。芯片按三年折，收入回收要七年，这个错配藏在现金流里。"),
        TranscriptLine(t: 336, text: "所以崩不崩不是重点。重点是估值回落的时候，谁能活下来。"),
    ]


    /// 分段样本。9 段是实测出来的段数（10 分钟的视频），
    /// 用它做截图才知道「真到 9 段时会不会挤」。
    static let sampleSegments: [APISegment] = [
        APISegment(title: "先给结论：缺口在哪", t: 0,
                   summary: "开场不谈涨跌，先把「估值」和「收入」两条线摆在一起，缺口一眼可见。"),
        APISegment(title: "和 2000 年像的地方", t: 62,
                   summary: "叙事驱动定价、散户集中入场、卖方报告互相引用同一套假设。"),
        APISegment(title: "不一样的地方：真在用的基建", t: 155,
                   summary: "算力与电力是真的被消耗掉的，这部分收入能对上账。"),
        APISegment(title: "资本开支的回收周期", t: 248,
                   summary: "折旧年限被拉长，利润表比现金流好看，这是容易被忽略的一层。"),
        APISegment(title: "谁在付钱", t: 341,
                   summary: "企业客户占比上升，但预算来自实验经费而不是生产预算。"),
        APISegment(title: "两个反方观点", t: 430,
                   summary: "作者没有一边倒：给出「这次不一样」的最强论据，再逐条拆。"),
        APISegment(title: "崩不崩不是重点", t: 525,
                   summary: "重点是谁能在估值回落时活下来，而不是预测哪一天回落。"),
        APISegment(title: "对普通人的含义", t: 618,
                   summary: "别把判断押在时间点上；把仓位和现金流留出余地。"),
        APISegment(title: "结尾的自我修正", t: 700,
                   summary: "作者承认自己上一次也判断错了时间，这段是整条片子里最诚实的地方。"),
    ]

    /// 标签页样本：一份像「真跑过几轮摘要」的分布——
    /// 「效率」压在 6 条上，而不是每个标签各 1 条。
    static let sampleTagPlan: [(Int, [String])] = [
        (0, ["AI", "科技"]),
        (1, ["效率", "学习"]),
        (2, ["效率", "心理"]),
        (3, ["学习", "效率"]),
        (4, ["产品", "设计"]),
        (5, ["效率"]),
        (6, ["产品", "心理"]),
        (7, ["效率", "健康"]),
    ]

    /// 脑图样本：三个分支，每个 2–3 个叶子。分支名都是概念短语，不含时间词。
    static let sampleOutline: [OutlineNode] = [
        OutlineNode(title: "泡沫形成的条件", note: "", children: [
            OutlineNode(title: "廉价资本", note: "长期低利率把资金推进高风险资产"),
            OutlineNode(title: "叙事替代盈利", note: "估值锚点从利润转向想象空间"),
            OutlineNode(title: "退出通道顺畅", note: "并购与上市让早期资金顺利退出"),
        ]),
        OutlineNode(title: "这次不一样的地方", note: "", children: [
            OutlineNode(title: "基础设施真在用", note: "算力与云是实际支出现金流的"),
            OutlineNode(title: "头部集中度更高", note: "缺口集中在少数几家公司"),
        ]),
        OutlineNode(title: "被忽略的风险", note: "", children: [
            OutlineNode(title: "折旧周期错配", note: "芯片折旧 3 年，收入回收 7 年"),
            OutlineNode(title: "定价权不在应用层", note: ""),
        ]),
    ]

    /// 书签样本：故意放得很稀（3 个），因为真实使用里人不会标 9 个点。
    static let sampleBookmarks: [APIBookmark] = [
        APIBookmark(t: 96, note: "这里给的三组对照数据，值得再看一遍", by: "user"),
        APIBookmark(t: 402, note: "", by: "user"),
        APIBookmark(t: 733, note: "作者承认上次也判断错了时间", by: "ai"),
    ]

    /// 模型列表样本。挑的都是真实存在的 id，备注按本地的名字规则推。
    static let sampleModels: [AIModel] = [
        AIModel(id: "Qwen/Qwen2.5-7B-Instruct", note: "通义千问 · 对话模型", chattable: true),
        AIModel(id: "Qwen/Qwen2.5-72B-Instruct", note: "通义千问 · 对话模型", chattable: true),
        AIModel(id: "deepseek-ai/DeepSeek-V3", note: "DeepSeek · 对话模型", chattable: true),
        AIModel(id: "deepseek-ai/DeepSeek-R1", note: "DeepSeek · 推理模型", chattable: true),
        AIModel(id: "Qwen/Qwen2-VL-72B-Instruct", note: "通义千问 · 视觉理解", chattable: true),
        AIModel(id: "BAAI/bge-m3", note: "向量模型", chattable: false),
        AIModel(id: "BAAI/bge-reranker-v2-m3", note: "重排模型", chattable: false),
        AIModel(id: "FunAudioLLM/SenseVoiceSmall", note: "语音识别", chattable: false),
    ]

    /// 评论区样本。刻意超过 20 条，且带楼层/点赞/时间——
    /// 验「评论区快照」区块能渲染，同时证明列表不会被「加载更多」用 20 条覆盖。
    static let sampleComments: [APIComment] = [
        APIComment(author: "肥鱼肥鱼大", text: "每天看B站日报的我：椅子、核弹、震惊、瘫坐",
                   likes: 231, replies: [APICommentReply(author: "路人甲", text: "太真实了")],
                   replyCount: 8, cid: "c1", created: 1794154512),
        APIComment(author: "比尔乔布斯", text: "我今天看的新闻是fable 5.5废了，内部很多人跑路。真假啊",
                   likes: 118, replyCount: 0, cid: "c2", created: 1794475068),
        APIComment(author: "代码侠", text: "这期讲得真透，收藏了",
                   likes: 87, replyCount: 3, cid: "c3", created: 1794380000),
        APIComment(author: "早睡星人", text: "看到一半意识到自己也在追热点，赶紧停下来想清楚",
                   likes: 64, replyCount: 0, cid: "c4", created: 1794360000),
        APIComment(author: "产品经理小王", text: "这波 AI 工具比去年强太多了，但落地还是看场景",
                   likes: 52, replyCount: 1, cid: "c5", created: 1794330000),
        APIComment(author: "数据猿", text: "补充一个数据点：现在模型的单位成本还在快速下降",
                   likes: 41, replyCount: 0, cid: "c6", created: 1794310000),
        APIComment(author: "前端阿强", text: "收藏夹吃灰 +1",
                   likes: 38, replyCount: 0, cid: "c7", created: 1794280000),
        APIComment(author: "独立开发者", text: "已经用上了，省了至少一半时间",
                   likes: 35, replyCount: 2, cid: "c8", created: 1794250000),
        APIComment(author: "考研党", text: "先码住，考完再回来学",
                   likes: 29, replyCount: 0, cid: "c9", created: 1794220000),
        APIComment(author: "夜猫子", text: "凌晨三点看这个，思路清晰得可怕",
                   likes: 26, replyCount: 0, cid: "c10", created: 1794200000),
        APIComment(author: "运营老张", text: "第二段那个案例我们公司正好用得上",
                   likes: 22, replyCount: 0, cid: "c11", created: 1794180000),
        APIComment(author: "学生小林", text: "老师推荐来看的，确实不错",
                   likes: 19, replyCount: 0, cid: "c12", created: 1794160000),
        APIComment(author: "设计狮", text: "封面图就很抓人，点进来没失望",
                   likes: 17, replyCount: 0, cid: "c13", created: 1794140000),
        APIComment(author: "算法工程师", text: "想听作者展开讲讲多模态那一块",
                   likes: 15, replyCount: 1, cid: "c14", created: 1794120000),
        APIComment(author: "白嫖党", text: "先三连再看",
                   likes: 12, replyCount: 0, cid: "c15", created: 1794100000),
        APIComment(author: "知识区常客", text: "这质量放在知识区也是第一梯队",
                   likes: 9, replyCount: 0, cid: "c16", created: 1794080000),
        APIComment(author: "路人乙", text: "评论区比视频还精彩",
                   likes: 8, replyCount: 0, cid: "c17", created: 1794060000),
        APIComment(author: "研究生小刘", text: "论文综述可以用这个思路",
                   likes: 6, replyCount: 0, cid: "c18", created: 1794040000),
        APIComment(author: "创业哥", text: "找投资前先把这个看完",
                   likes: 5, replyCount: 0, cid: "c19", created: 1794020000),
        APIComment(author: "潜水艇", text: "看了三遍，每次都有新收获",
                   likes: 3, replyCount: 0, cid: "c20", created: 1794000000),
    ]

    /// 发现页样本：分类 + 热榜 + 合集 + 「你存过的」。
    static let sampleDiscoverFeed: APIDiscoverFeed = {
        func item(_ id: String, _ title: String, _ cat: String,
                  _ author: String, _ views: Int, duration: Int) -> APIDiscoverItem {
            APIDiscoverItem(id: id, platform: "bilibili", title: title, author: author,
                            views: views, duration: duration, url: "https://www.bilibili.com/video/\(id)",
                            category: cat, interest: 1)
        }
        let hot = [
            item("BV1a", "AI 帮你写代码，Cursor 到底值不值得上手", "AI", "产品君", 120000, 742),
            item("BV1b", "大模型参数越多越好吗？一次讲清楚", "AI", "科技袁人", 98000, 630),
            item("BV1c", "Rust 为什么越来越火", "编程", "代码随想录", 76000, 518),
            item("BV1d", "半导体行业还能上车吗", "科技", "硬核财经", 88000, 445),
            item("BV1e", "量子力学的通俗解释", "科普", "李永乐老师", 156000, 900),
            item("BV1f", "副业怎么选：接单还是做产品", "商业", "商业小纸条", 54000, 380),
        ]
        let sections = [
            APIDiscoverSection(category: "AI", items: Array(hot.prefix(2))),
            APIDiscoverSection(category: "编程", items: Array(hot[2...2])),
            APIDiscoverSection(category: "科技", items: Array(hot[3...3])),
            APIDiscoverSection(category: "科普", items: Array(hot[4...4])),
            APIDiscoverSection(category: "商业", items: Array(hot[5...5])),
        ]
        let collections = [
            APIDiscoverCollection(seasonId: "s1", itemId: "seed0000000001", title: "AI生产力",
                                  total: 300, index: 299, episodeTitle: "盘点一周 AI 大事", cover: ""),
            APIDiscoverCollection(seasonId: "s2", itemId: "seed0000000002", title: "科技每周补全",
                                  total: 125, index: 124, episodeTitle: "本周科技新闻", cover: ""),
        ]
        return APIDiscoverFeed(ok: true, fetchedAt: Int(Date().timeIntervalSince1970 * 1000),
                               categories: ["全部", "AI", "编程", "科技", "科普", "商业", "合集"],
                               sections: sections, collections: collections, blockedCats: [],
                               hot: hot, mine: [], keywords: ["AI"])
    }()
}
