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

    init(state: String, appearance: ColorScheme?) {
        self.state = state
        self.appearance = appearance
        _tab = State(initialValue: state == "me" ? 1 : 0)

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

        // 作者行：详情页截图要能看到头像、名字、备注入口
        if state.hasPrefix("detail"), let id = detail?.id {
            // 故意把 author/videoId 留空，模拟线上那 4 条存量数据：
            // 只有 metaLine 里的作者名、没有 bvid。截图要验的正是这条兜底路径。
            lib.seedAuthor(id: id, author: "", authorId: "", videoId: "",
                           note: "讲存储很扎实，适合看架构")
            lib.seedNote(id: id, note: "他的三组对照实验部分可以直接套到我们下季度的容量评估里。\n另外开头的那个提问方式值得学。")
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
            } else if state == "tags" {
                NavigationStack { TagsScreen() }
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
    }

    private var tabs: some View {
        TabView(selection: $tab) {
            NavigationStack {
                HomeScreen(
                    initialSelection: detailItem,
                    detailPrepare: detailPrepare,
                    showsImport: state == "import"
                )
            }
            .tabItem { Label("首页", systemImage: "house.fill") }
            .tag(0)

            NavigationStack {
                MeScreen()
            }
            .tabItem { Label("我", systemImage: "person.fill") }
            .tag(1)
        }
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
}
