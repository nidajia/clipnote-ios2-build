import SwiftUI

/// 首页筛选。
///
/// **单选**：同一时刻只有一个筛选生效，点了分区就离开「视频/笔记」那一类。
/// 和 B 站一致——进来就在某个分区里，不是层层叠加条件。
///
/// 不做叠加是有意的：两个条件同时生效之后，「列表空了」就变得没法解释——
/// 到底是这条不在，还是两个条件互斥？单选只有一种解释。
enum HomeFilter: Hashable, Identifiable {
    case all
    case section(String)
    case unassigned
    case video
    case note
    case downloaded

    var id: String {
        switch self {
        case .all: return "all"
        case .section(let id): return "section:" + id
        case .unassigned: return "unassigned"
        case .video: return "video"
        case .note: return "note"
        case .downloaded: return "downloaded"
        }
    }
}

/// 首页（画布 03 / 10）
///
/// 结构选择：系统 `List` 而不是 `ScrollView + LazyVStack`。
/// 后者会让 `swipeActions` 失效——上一版就栽在这里。
///
/// 数据来自 `LibraryStore`（线上 `/api/v2/library`）。
/// 「是否已下载」只问 `DownloadStore`，行内不再存第二份状态。
struct HomeScreen: View {
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var downloads: DownloadStore
    @EnvironmentObject private var sections: SectionStore
    @EnvironmentObject private var statuses: StatusStore
    @Environment(\.colorScheme) private var scheme

    @State private var query = ""
    /// 多选模式。选中的 id 存集合，`filtered` 变化不会让已选项悄悄失效。
    @State private var selecting = false
    @State private var picked = Set<String>()
    @State private var confirmBatchDelete = false
    @State private var batchWorking = false
    /// 本机已缓存的字幕，供搜索用。只读不写。
    @State private var transcripts: [String: [TranscriptLine]] = [:]
    /// 从搜索结果点进详情时要定位到的秒数。
    @State private var focusTranscriptAt: Int?
    @State private var filter: HomeFilter = .all
    @State private var showImport = false
    @State private var showAsk = false
    /// 手动刷新中。下拉刷新有自己的转圈，这个只给导航栏按钮用。
    @State private var refreshing = false
    @State private var showBatchSections = false
    @State private var selected: Item?
    /// 正在看哪条笔记。笔记是**直接进编辑器**的，不经过视频详情页——
    /// 之前点一条笔记要先落到视频页，再点「笔记」才能写，两步都是多余的。
    @State private var openedNote: Item?
    @State private var showNewNote = false
    @State private var newNoteTitle = ""
    /// 刚从模板建出来的笔记：进编辑器后光标落到文末。
    @State private var autoFocusNote = false
    @State private var toast: String?

    /// `initialSelection` 只给截图用：让详情页以「被 push 进去」的形态出现，
    /// 否则它会是导航栈的根，截图上没有返回按钮。
    /// `detailPrepare` 同理：让「已取到播放地址」这一态能被拍下来。
    /// `previewFilter` 让分区筛选态能被拍到——`@State` 从外部无法设置。
    init(
        initialSelection: Item? = nil,
        detailPrepare: DetailScreen.PrepareState? = nil,
        showsImport: Bool = false,
        previewSelecting: Bool = false,
        previewFilter: HomeFilter? = nil
    ) {
        _selected = State(initialValue: initialSelection)
        _showImport = State(initialValue: showsImport)
        _selecting = State(initialValue: previewSelecting)
        if let previewFilter { _filter = State(initialValue: previewFilter) }
        self.detailPrepare = detailPrepare
    }

    private let detailPrepare: DetailScreen.PrepareState?

    private var items: [Item] { library.items }

    /// 列表最终展示的条目。
    ///
    /// 在筛选结果之上再折叠一次：**同一个合集只留最新一集**。
    /// 用户存「每周 AI 大事」会一条条攒，不折叠的话首页会被同一部作品的
    /// 十几个分集撑满，别的内容全被挤下去。点进去在详情页能看到整个合集。
    private var filtered: [Item] {
        let raw = filteredRaw
        var best: [String: Item] = [:]
        for one in raw where !one.seasonId.isEmpty {
            if let cur = best[one.seasonId], cur.seasonIndex >= one.seasonIndex { continue }
            best[one.seasonId] = one
        }
        guard !best.isEmpty else { return raw }
        var placed: Set<String> = []
        return raw.compactMap { one in
            if one.seasonId.isEmpty { return one }
            guard let champion = best[one.seasonId] else { return one }
            guard champion.id == one.id, !placed.contains(one.seasonId) else { return nil }
            placed.insert(one.seasonId)
            return one
        }
    }

    private var filteredRaw: [Item] {
        var list = items
        switch filter {
        case .all: break
        case .section(let id): list = list.filter { sections.sectionID(for: $0.id) == id }
        case .unassigned: list = list.filter { sections.sectionID(for: $0.id) == nil }
        // 「视频」这一档的语义其实是「导入的内容」（相对「自己写的笔记」）。
        // 图文作品的 kind 是 image，按 == .video 过滤会让它凭空消失——
        // 只在「全部」里能看到，用户会以为导入失败了。
        case .video: list = list.filter { $0.kind != .note }
        case .note:
            // 「笔记」不是指 kind，而是**真的有笔记内容**。
            // 之前按 kind 过滤，把建了条目还没写字的也算进来，
            // 于是列表里全是空笔记，点进去什么都没有。
            list = list.filter { !$0.note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        case .downloaded: list = list.filter { downloads.isDownloaded($0.id) }
        }
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return list }
        // 交给 LibrarySearch：字段清单和输入框文案必须在一个地方，
        // 分开写就会出现「写着能搜标签，实际搜不到」。
        // 分区不在 Item 里（它是本地归属），所以由这里递进去。
        return list.filter {
            LibrarySearch.matches($0, query: q,
                                   extra: [sections.section(for: $0.id)?.name ?? "",
                                           statuses.status(for: $0.id)?.title ?? ""])
                || !TranscriptIndex.hits(in: transcripts[$0.id] ?? [], query: q, limit: 3).isEmpty
        }
    }

    /// 筛选条上的胶囊。分区在前——「我为什么存它」比「它是什么形态」更常用。
    private struct FilterChipSpec: Identifiable {
        var filter: HomeFilter
        var title: String
        /// 这一颗前面要插一条分组竖线，把「分区」和「形态」分开
        var startsGroup = false
        var id: String { filter.id }
    }

    private var filterChips: [FilterChipSpec] {
        var out: [FilterChipSpec] = [.init(filter: .all, title: "全部")]
        for section in sections.allSections {
            out.append(.init(filter: .section(section.id), title: section.name))
        }
        // 「未分区」只在真有未分区的条目时出现。刚用起来的时候它等于「全部」，
        // 白占一格；等条目都归好类，它又会自己消失。
        if !items.isEmpty, items.contains(where: { sections.sectionID(for: $0.id) == nil }) {
            out.append(.init(filter: .unassigned, title: "未分区"))
        }
        out.append(.init(filter: .video, title: "视频", startsGroup: true))
        out.append(.init(filter: .note, title: "笔记"))
        out.append(.init(filter: .downloaded, title: "已下载"))
        return out
    }

    /// 笔记直达编辑器的布尔投影。
    private var notePushed: Binding<Bool> {
        Binding(
            get: { openedNote != nil },
            set: { if !$0 { openedNote = nil; autoFocusNote = false } }
        )
    }

    /// `selected` 的布尔投影，供 iOS 16 的 navigationDestination(isPresented:) 使用。
    private var detailPushed: Binding<Bool> {
        Binding(
            get: { selected != nil },
            set: { if !$0 { selected = nil; focusTranscriptAt = nil } }
        )
    }

    var body: some View {
        content
            // 下拉刷新。之前没有这个控件，下拉只是滚动，大标题跟着走——
            // 用户的感受是「存了新的看不到，也没地方刷」。
            .refreshable { await library.reload() }
            .background(Color.cnBg)
            .navigationTitle("片记")
            .navigationBarTitleDisplayMode(.large)
            // 不用 `.searchable`：iOS 16 下它的抽屉高度与大标题折叠会互相触发。
            // 列表内容刚好卡在「勉强可滚动」的边界时，导航栏会**不需要任何输入**
            // 就持续上下抽动，而导入按钮正夹在那两者中间（真机复现）。
            // 自绘一个搜索框放进固定头部，导航栏就只剩标题，没有第二个变高度的头。
            .safeAreaInset(edge: .top, spacing: 0) { pinnedHeader }
            // `navigationDestination(item:)` 是 iOS 17 才有的；16 上要用 isPresented
            // 自己包一层。包出来的行为一致：selected 有值时推入，返回时置空。
            .navigationDestination(isPresented: notePushed) {
                if let openedNote {
                    NoteScreen(item: openedNote, beginAtEnd: autoFocusNote)
                }
            }
            .navigationDestination(isPresented: detailPushed) {
                if let selected {
                    DetailScreen(item: selected,
                                 initialPrepare: detailPrepare,
                                 focusTranscriptAt: focusTranscriptAt)
                }
            }
            .task {
                // 只读本机已缓存的字幕：搜索是每敲一下就重算的路径，
                // 不能在这条路径上打网络。
                transcripts = TranscriptIndex.load(itemIds: library.items.map(\.id))
            }
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    if !selecting {
                        HStack(spacing: Metric.space3) {
                            // 显式刷新入口。下拉也能刷，但「看不到新内容」时
                            // 用户第一反应是找一个按钮，而不是去猜手势。
                            Button {
                                Task {
                                    refreshing = true
                                    await library.reload()
                                    refreshing = false
                                }
                            } label: {
                                if refreshing {
                                    RingSpinner(size: 14, color: .cnBrand)
                                } else {
                                    Image(systemName: "arrow.clockwise")
                                        .font(.system(size: 15, weight: .semibold))
                                        .foregroundStyle(Color.cnInk2)
                                }
                            }
                            .buttonStyle(.plain)
                            .disabled(refreshing)
                            .accessibilityLabel("刷新")

                            // 带文字而不是纯图标：一个陌生的 sparkle 图标
                            // 用户根本不会去点（实测反馈「问库在哪」）。
                            Button {
                                showAsk = true
                            } label: {
                                HStack(spacing: 3) {
                                    Image(systemName: "sparkle")
                                        .font(.system(size: 11, weight: .semibold))
                                    Text("问库")
                                        .font(.cnChip)
                                }
                                .foregroundStyle(Color.cnBrand)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("问库")

                            Button {
                                showImport = true
                            } label: {
                                importLabel
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .sheet(isPresented: $showAsk) {
                NavigationStack { AskScreen() }
            }
            // 多选时底部浮出操作条。不用 toolbar 的 bottomBar：
            // 那条会和 tabBar 抢位置，而 tabBar 在本页是可见的。
            .overlay(alignment: .bottom) {
                if selecting {
                    batchBar
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .alert("移到回收站？", isPresented: $confirmBatchDelete) {
                Button("取消", role: .cancel) {}
                Button("移到回收站", role: .destructive) {
                    Task { await runBatchDelete() }
                }
            } message: {
                Text("选中的 \(picked.count) 条会进回收站，30 天内可以恢复。")
            }
            .sheet(isPresented: $showImport) {
                ImportSheet { title in
                    Task { await createNote(title: title) }
                }
            }
            .alert("新建笔记", isPresented: $showNewNote) {
                TextField("标题", text: $newNoteTitle)
                Button("取消", role: .cancel) {}
                Button("创建") {
                    let title = newNoteTitle.trimmingCharacters(in: .whitespacesAndNewlines)
                    newNoteTitle = ""
                    guard !title.isEmpty else { return }
                    Task { await createNote(title: title) }
                }
            } message: {
                Text("会带好大标题和三个小标题，直接往里填就行。")
            }
            .sheet(isPresented: $showBatchSections) {
                NavigationStack {
                    SectionPickerSheet(
                        store: sections,
                        current: pickedCommonSection,
                        count: picked.count
                    ) { id in
                        applyBatchSection(id)
                    }
                }
            }
            // 分区被删掉时，不能把一个指向不存在分区的筛选留在原地：
            // 那会显示一个永远空着的列表，看起来像数据丢了。
            .onChange(of: sections.allSections) { list in
                if case .section(let id) = filter,
                   !list.contains(where: { $0.id == id }) {
                    filter = .all
                }
            }
            .overlay(alignment: .bottom) { toastView }
    }

    /// 轻量提示。删除是软删，用户得知道「东西还在回收站」，否则会以为彻底没了。
    @ViewBuilder
    private var toastView: some View {
        if let toast {
            Text(toast)
                .font(.cnMeta)
                .foregroundStyle(Color.cnBg)
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .background(Color.cnInk.opacity(0.88), in: Capsule())
                .padding(.bottom, 72)
                .transition(.opacity)
        }
    }

    private func showToast(_ text: String) {
        withAnimation { toast = text }
        Task {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            withAnimation { toast = nil }
        }
    }

    @ViewBuilder
    private var content: some View {
        // 已经有数据时不显示全屏加载/失败，避免刷新把列表整块换掉闪一下
        if !items.isEmpty {
            listOrNoResults
        } else {
            switch library.phase {
            case .idle, .loading:
                LoadingStateView()
            case .failed(let message):
                LoadFailureView(message: message) {
                    Task { await library.reload() }
                }
            case .loaded:
                EmptyStateView(onImport: { showImport = true })
            }
        }
    }

    @ViewBuilder
    private var listOrNoResults: some View {
        // 「一条笔记都没有」和「筛选没命中」是两件事。
        // 前者要请用户写一条，后者只要换个条件。
        if filter == .note, filtered.isEmpty {
            NotesEmptyView { showNewNote = true }
        } else if filtered.isEmpty {
            // 有数据但筛不出来，不能复用「还没有条目」的文案
            NoResultsView {
                query = ""
                filter = .all
            }
        } else {
            List(filtered) { item in
                Button {
                    if selecting {
                        if picked.contains(item.id) { picked.remove(item.id) }
                        else { picked.insert(item.id) }
                    } else {
                        open(item)
                    }
                } label: {
                    VStack(alignment: .leading, spacing: 0) {
                        HStack(spacing: Metric.space2) {
                            if selecting {
                                Image(systemName: picked.contains(item.id)
                                      ? "checkmark.circle.fill" : "circle")
                                    .font(.system(size: 19, weight: .regular))
                                    .foregroundStyle(picked.contains(item.id)
                                                     ? Color.cnBrand : Color.cnInk3)
                            }
                            ItemRow(model: item,
                                    isDownloaded: downloads.isDownloaded(item.id),
                                    section: sections.section(for: item.id),
                                    status: statuses.status(for: item.id),
                                    subtitle: subtitle(for: item))
                        }

                        // 字幕命中单独一行，是**独立按钮**：点它会直接去那一句，
                        // 点条目的其余部分仍然是打开详情。
                        // 两者语义不同，不该挤在同一个点击区域里。
                        if !selecting, let hit = transcriptHit(for: item) {
                            Button {
                                focusTranscriptAt = hit.t
                                selected = item
                            } label: {
                                HStack(spacing: 6) {
                                    Image(systemName: "captions.bubble")
                                        .font(.system(size: 10, weight: .semibold))
                                    Text(mmss(hit.t))
                                        .font(.cnMeta)
                                    Text(hit.text)
                                        .font(.cnMeta)
                                        .lineLimit(1)
                                    Spacer(minLength: 0)
                                    Image(systemName: "chevron.right")
                                        .font(.system(size: 8, weight: .semibold))
                                }
                                .foregroundStyle(Color.cnBrand)
                                .padding(.vertical, 5)
                                .padding(.leading, selecting ? 27 : 0)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .buttonStyle(.plain)
                // 左滑删除。当初选 List 而不是自绘列表，唯一的技术理由就是它能用。
                // allowsFullSwipe: false —— 一整条划过去就删掉太容易误触，
                // 而这条可能是花了 130 MB 流量下下来的。
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    Button(role: .destructive) {
                        Task {
                            let ok = await library.delete(item)
                            if ok { sections.forget([item.id]) }
                            showToast(ok ? "已移到回收站" : "删除失败，请重试")
                        }
                    } label: {
                        Label("删除", systemImage: "trash")
                    }
                }
                // 长按归类。批量入口在多选底栏，但「边看边归」是逐条的：
                // 每归一条都进一次详情页，这件事就没人愿意做了。
                .contextMenu {
                    Menu {
                        Button {
                            assign(nil, to: [item.id])
                        } label: {
                            Label("未分区", systemImage: "tray")
                        }
                        ForEach(sections.allSections) { section in
                            Button {
                                assign(section.id, to: [item.id])
                            } label: {
                                Label(section.name, systemImage: section.symbol)
                            }
                        }
                    } label: {
                        Label("移到分区", systemImage: "square.grid.2x2")
                    }

                    Menu {
                        Button {
                            setStatus(nil, on: [item.id])
                        } label: {
                            Label("清除标记", systemImage: "xmark.circle")
                        }
                        ForEach(ItemStatus.allCases) { status in
                            Button {
                                setStatus(status, on: [item.id])
                            } label: {
                                Label(status.title, systemImage: status.symbol)
                            }
                        }
                    } label: {
                        Label("状态", systemImage: "circle.dashed")
                    }
                }
                .listRowInsets(EdgeInsets(
                    top: 0,
                    leading: Metric.pagePad,
                    bottom: 0,
                    trailing: Metric.pagePad
                ))
                .listRowBackground(Color.cnBg)
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            // 自绘搜索框后，滚动时得自己收键盘（系统搜索框以前管这件事）
            .scrollDismissesKeyboard(.immediately)
            // 行本身不再硬关分隔线，由这里统一定义颜色
            .listRowSeparatorTint(Color.cnCard2)
            .listRowSpacing(0)
        }
    }

    private func transcriptHit(for item: Item) -> TranscriptHit? {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return nil }
        return TranscriptIndex.hits(in: transcripts[item.id] ?? [], query: q, limit: 1).first
    }

    private func mmss(_ seconds: Int) -> String {
        let s = max(0, seconds)
        if s >= 3600 {
            return String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60)
        }
        return String(format: "%d:%02d", s / 60, s % 60)
    }

    /// 多选时底部浮出的操作条。
    private var batchBar: some View {
        VStack(spacing: 0) {
            Rectangle().fill(Color.cnHairlineSoft).frame(height: 1)
            HStack(spacing: Metric.space3) {
                Text(picked.isEmpty ? "选择要处理的条目" : "已选 \(picked.count) 条")
                    .font(.cnChip)
                    .foregroundStyle(picked.isEmpty ? Color.cnInk3 : Color.cnInk)

                Spacer(minLength: 0)

                // 「导入一多就乱」本来就是个批量问题：一条条点是最慢的路。
                // 所以分区在多选底栏里，和删除并列。
                Button {
                    showBatchSections = true
                } label: {
                    Text("分区")
                        .font(.cnChip)
                        .foregroundStyle(picked.isEmpty ? Color.cnInk3 : Color.cnBrand)
                        .padding(.horizontal, Metric.space3)
                        .padding(.vertical, 8)
                        .background(
                            (picked.isEmpty ? Color.cnCard3 : Color.cnBrandSoft),
                            in: Capsule()
                        )
                }
                .buttonStyle(.plain)
                .disabled(picked.isEmpty || batchWorking)

                Button {
                    confirmBatchDelete = true
                } label: {
                    Text(batchWorking ? "处理中…" : "移到回收站")
                        .font(.cnChip)
                        .foregroundStyle(picked.isEmpty ? Color.cnInk3 : Color.cnRed)
                        .padding(.horizontal, Metric.space3)
                        .padding(.vertical, 8)
                        .background(
                            (picked.isEmpty ? Color.cnCard3 : Color.cnRed.opacity(0.14)),
                            in: Capsule()
                        )
                }
                .buttonStyle(.plain)
                .disabled(picked.isEmpty || batchWorking)
            }
            .padding(.horizontal, Metric.pagePad)
            .padding(.vertical, Metric.space2)
        }
        .background(Color.cnBg)
    }

    private func runBatchDelete() async {
        guard !picked.isEmpty, !batchWorking else { return }
        batchWorking = true
        defer { batchWorking = false }

        let ids = Array(picked)
        guard let count = await library.batchDelete(ids: ids) else {
            showToast("批量删除失败，请重试")
            return
        }
        // 条目走了，归属也要走：留着会让 sections.json 无限长下去。
        sections.forget(ids)
        showToast("已把 \(count) 条移到回收站")
        withAnimation(.easeInOut(duration: 0.18)) {
            selecting = false
            picked.removeAll()
        }
    }

    /// 点一条内容。
    ///
    /// 笔记（以及「笔记」筛选下的任何条目）直接进编辑器；
    /// 其它进详情页——那里才是播放器和 AI 摘要。
    private func open(_ item: Item) {
        let isNote = item.kind == .note
            || (filter == .note && !item.note.isEmpty)
        if isNote {
            openedNote = item
        } else {
            selected = item
        }
    }

    private func createNote(title: String) async {
        switch await library.createNote(title: title) {
        case .success(let item):
            autoFocusNote = true
            openedNote = item
            filter = .note
        case .failure(let failure):
            showToast("新建失败：\(failure.displayMessage)")
        }
    }

    /// 笔记行的副标题：带上最后修改时间。
    ///
    /// 为什么只留平台、不留作者：这一行还要放状态与分区两个徽章，
    /// 而「11-11 07:20」这种完整时间会被挤成「11-1…」——日期缺一半，
    /// 等于没显示。改成相对时间（3 小时前 / 昨天 / 10-26），既短又够用。
    private func subtitle(for item: Item) -> String? {
        let stamp = item.noteTouchedAt.map(Self.stamp)
        if item.kind == .note {
            // 笔记条目的 metaLine 就是「笔记」，不用再占字
            return stamp.map { "笔记 · \($0)" } ?? "笔记"
        }
        // 视频条目也能写笔记。在「笔记」筛选下列出来的就是这些，
        // 没有时间的话，「什么时候写的」还得点进去才知道。
        let hasNote = !item.note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        guard hasNote else { return nil }
        // 只要平台，不要作者：作者名往往很长，而这一行已经有徽章要放
        let platform = item.metaLine.components(separatedBy: " · ").first ?? item.metaLine
        return stamp.map { "\(platform) · \($0)" } ?? item.metaLine
    }

    /// 紧凑时间：今天给「3 小时前」，昨天给「昨天」，再往前给日期。
    ///
    /// 列表行只有一行位置，而完整时间会被徽章挤掉后半截。
    /// 精确到分钟对「什么时候写的」没有帮助——「上周三」比「11-04 23:40」更好判断。
    static func stamp(_ date: Date) -> String {
        let now = Date()
        let seconds = now.timeIntervalSince(date)
        if seconds < 60 { return "刚刚" }
        if seconds < 3600 { return "\(Int(seconds / 60)) 分钟前" }

        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return "\(Int(seconds / 3600)) 小时前" }
        if calendar.isDateInYesterday(date) { return "昨天" }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = calendar.component(.year, from: date) == calendar.component(.year, from: now)
            ? "MM-dd"
            : "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    /// 改状态并给一句反馈。批量入口留着：多选底栏要接的时候直接复用。
    private func setStatus(_ status: ItemStatus?, on ids: [String]) {
        let changed = statuses.set(status, for: ids)
        guard changed > 0 else { return }
        showToast(status.map { "已标为「\($0.title)」" } ?? "已清除状态")
    }

    // MARK: - 分区

    /// 选中项的共同分区。多选时若各不相同则为 nil——此时面板上不显示勾，
    /// 免得让人以为「已经被归到某一类了」。
    private var pickedCommonSection: String? {
        let ids = Set(picked.map { sections.sectionID(for: $0) ?? "" })
        guard ids.count == 1, let only = ids.first else { return nil }
        return only.isEmpty ? nil : only
    }

    /// 归类并说话。没有改动时也要说——静默是最糟的反馈。
    private func assign(_ sectionID: String?, to ids: [String]) {
        let changed = sections.assign(sectionID, to: ids)
        let name = sectionID.flatMap { sections.section(id: $0)?.name } ?? "未分区"
        guard changed > 0 else {
            showToast("这些条目已经在这个分区里")
            return
        }
        showToast(ids.count > 1 ? "已把 \(changed) 条移到「\(name)」" : "已移到「\(name)」")
    }

    private func applyBatchSection(_ sectionID: String?) {
        assign(sectionID, to: Array(picked))
        showBatchSections = false
        withAnimation(.easeInOut(duration: 0.18)) {
            selecting = false
            picked.removeAll()
        }
    }

    /// 钉在顶部的整块头部：搜索框 + 筛选条，一个固定高度，不随列表滚动
    private var pinnedHeader: some View {
        VStack(spacing: 0) {
            HStack(spacing: Metric.space2) {
                searchField
                // 「选择」放在自定义头部而不是导航栏。
                //
                // 上一版放在 navigationBarLeading，真机上用户找不到（v42）。
                // 导航栏那块区域的可见性我没法从代码确认，而头部是我们自己画的，
                // 一定在视线里。功能做得出来却找不到入口，等于没做。
                if !filtered.isEmpty {
                    Button(selecting ? "取消" : "选择") {
                        withAnimation(.easeInOut(duration: 0.18)) {
                            selecting.toggle()
                            picked.removeAll()
                        }
                    }
                    .font(.cnChip)
                    .foregroundStyle(selecting ? Color.cnInk3 : Color.cnBrand)
                    .frame(minWidth: 40, alignment: .trailing)
                }
            }
            .padding(.horizontal, Metric.pagePad)
            .padding(.top, Metric.space2)
            .padding(.bottom, Metric.space1)

            filterBar

            if !library.failedImports.isEmpty {
                failedImportsBar
            }
        }
        .background(Color.cnBg)
    }

    /// 快捷导入失败的提示条。
    ///
    /// 快捷指令是静默的：存失败时用户看到的只是「我明明存了，怎么没有」。
    /// 这条是唯一能告诉他「有东西没存上」的地方，所以放在搜索框下面、
    /// 不折叠、不自动消失。
    private var failedImportsBar: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.cnRed)
                Text("有 \(library.failedImports.count) 条没存上")
                    .font(.cnCaption)
                    .foregroundStyle(Color.cnInk)
                Spacer(minLength: 0)
                Button("重试") {
                    Task { await library.retryAllFailedImports() }
                }
                .font(.cnCaption)
                .foregroundStyle(Color.cnBrand)
                .buttonStyle(.plain)
                Button("忽略") {
                    Task { await library.dismissFailedImports() }
                }
                .font(.cnCaption)
                .foregroundStyle(Color.cnInk3)
                .buttonStyle(.plain)
            }
            if let first = library.failedImports.first, !first.reason.isEmpty {
                Text("最近一条：\(first.reason)")
                    .font(.cnCaption)
                    .foregroundStyle(Color.cnInk3)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, Metric.pagePad)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.cnRed.opacity(0.08))
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.cnInk3)

            TextField("搜索标题、作者、标签、分区、笔记", text: $query)
                .font(.cnBody)
                .foregroundStyle(Color.cnInk)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.search)

            // **不要用 if 包住这个按钮。**
            //
            // 之前是 `if !query.isEmpty { 清空按钮 }`：输入第一个字符后视图树多了一个子节点，
            // 而中文输入法正在组词（拼音还没上屏）——树一变，输入法会话被系统结束，
            // 表现就是「汉字只打了第一个字母就再也打不进去」。
            // 结构保持恒定，只改可见性与可点性。
            Button {
                query = ""
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(Color.cnInk3)
            }
            .buttonStyle(.plain)
            .opacity(query.isEmpty ? 0 : 1)
            .allowsHitTesting(!query.isEmpty)
            .accessibilityHidden(query.isEmpty)
            .accessibilityLabel("清空搜索")
        }
        .padding(.horizontal, 10)
        .frame(height: 36)
        .background(
            Color.cnCard2,
            in: RoundedRectangle(cornerRadius: 10, style: .continuous)
        )
    }

    /// 钉在顶部的筛选条，不随列表滚动。
    ///
    /// 一条横滑里放两组：分区（意图）在前，形态（视频/笔记/已下载）在后，
    /// 中间一条竖线分开。分区数量会随用户增长，所以这一条必须能横滑——
    /// 上一版四个固定胶囊不需要滑，加了分区就不成立了。
    private var filterBar: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: Metric.space2) {
                    ForEach(filterChips) { spec in
                        if spec.startsGroup {
                            Rectangle()
                                .fill(Color.cnHairline)
                                .frame(width: 1, height: 18)
                                .padding(.horizontal, 2)
                        }
                        Button {
                            filter = spec.filter
                        } label: {
                            FilterChip(title: spec.title, isSelected: spec.filter == filter)
                        }
                        .buttonStyle(.plain)
                        .id(spec.id)
                    }
                }
                .padding(.horizontal, Metric.pagePad)
                .padding(.vertical, Metric.space2)
            }
            // 选中的那一颗可能在屏幕外（分区一多就会），必须滚过去。
            // 否则用户切到「笔记」之后，条上看不到任何选中态——
            // 截图里就发生过：列表已经筛过了，但看上去像没生效。
            .onChange(of: filter) { value in
                withAnimation(.easeInOut(duration: 0.2)) {
                    proxy.scrollTo(value.id, anchor: .center)
                }
            }
            .onAppear {
                proxy.scrollTo(filter.id, anchor: .center)
            }
        }
        .background(Color.cnBg)
        // 右边缘渐隐：分区会越加越多，这一条一定得横滑。
        // 没有这个提示，看到「知识科普」就以为到头了——后面还有「视频/笔记/已下载」，
        // 那三个是上一版就有的筛选，不能被新功能挤到看不见的地方。
        .overlay(alignment: .trailing) {
            LinearGradient(
                colors: [Color.cnBg.opacity(0), Color.cnBg],
                startPoint: .leading,
                endPoint: .trailing
            )
            .frame(width: 24)
            .allowsHitTesting(false)
        }
    }

    /// 导航栏里的导入按钮：实心品牌底 + 高对比文字
    private var importLabel: some View {
        HStack(spacing: 4) {
            Image(systemName: "plus")
                .font(.system(size: 12, weight: .bold))
            Text("导入")
                .font(.cnChip)
        }
        .foregroundStyle(scheme == .dark ? Color.cnBg : .white)
        .padding(.horizontal, 11)
        .padding(.vertical, 6)
        .background(Color.cnBrand, in: Capsule())
        .accessibilityLabel("导入")
    }
}

// MARK: - 加载中

/// 用 `RingSpinner` 而不是 `ProgressView`：后者在离屏渲染下会变成橙色占位方块。
/// 现在整屏已经改走 `simctl`，但保持一致仍更安全。
struct LoadingStateView: View {
    var body: some View {
        VStack(spacing: Metric.space4) {
            // 用系统转圈而不是自绘的 RingSpinner：详见 ActivitySpinner 里的注释——
            // 自绘那个每帧都在改几何，会把导航栏里的「导入」按钮带着一起抖。
            ActivitySpinner(style: .large)
            Text("正在同步云端快照")
                .font(.cnChip)
                .foregroundStyle(Color.cnInk3)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - 加载失败

/// 这条态不是补丁：线上网关对每个路径都要求 `sharecode`，
/// 未知路径还会回落 HTML。失败是常态，必须有话说。
struct LoadFailureView: View {
    var message: String
    var onRetry: () -> Void

    var body: some View {
        VStack(spacing: Metric.space4) {
            ZStack {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(Color.cnCard2)
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 24, weight: .regular))
                    .foregroundStyle(Color.cnInk3)
            }
            .frame(width: 64, height: 64)

            Text("没能拉到云端数据")
                .font(.cnTitle)
                .foregroundStyle(Color.cnInk)

            Text(message)
                .font(.cnChip)
                .foregroundStyle(Color.cnInk3)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 280)

            PrimaryButton(title: "重试", action: onRetry)
                .frame(width: 180)
                .padding(.top, Metric.space1)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, Metric.pagePad)
    }
}

// MARK: - 无结果（有数据，但当前筛选/搜索为空）

struct NoResultsView: View {
    var onReset: () -> Void

    var body: some View {
        VStack(spacing: Metric.space4) {
            ZStack {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(Color.cnCard2)
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 24, weight: .regular))
                    .foregroundStyle(Color.cnInk3)
            }
            .frame(width: 64, height: 64)

            Text("没有符合条件的条目")
                .font(.cnTitle)
                .foregroundStyle(Color.cnInk)

            Text("换一个筛选条件，或清空搜索词再试。")
                .font(.cnChip)
                .foregroundStyle(Color.cnInk3)
                .multilineTextAlignment(.center)

            Button("清除筛选", action: onReset)
                .font(.cnChip)
                .foregroundStyle(Color.cnBrand)
                .padding(.top, Metric.space1)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, Metric.pagePad)
    }
}

// MARK: - 笔记空态

/// 「一条笔记都没有」。
///
/// 不复用 `EmptyStateView`（那是「库里什么都没有，去导入」）：
/// 这里用户已经有内容了，缺的只是笔记这一种，所以按钮是「写一条」而不是「导入」。
struct NotesEmptyView: View {
    var onCreate: () -> Void

    var body: some View {
        VStack(spacing: Metric.space4) {
            ZStack {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(Color.cnCard2)
                Image(systemName: "square.and.pencil")
                    .font(.system(size: 24, weight: .regular))
                    .foregroundStyle(Color.cnInk3)
            }
            .frame(width: 64, height: 64)

            Text("还没有笔记")
                .font(.cnTitle)
                .foregroundStyle(Color.cnInk)

            Text("笔记独立于视频：想到什么就写一条，不用先有链接。")
                .font(.cnChip)
                .foregroundStyle(Color.cnInk3)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 280)

            PrimaryButton(title: "写一条", action: onCreate)
                .frame(width: 180)
                .padding(.top, Metric.space1)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, Metric.pagePad)
    }
}

// MARK: - 空态（画布 10）

struct EmptyStateView: View {
    var onImport: () -> Void

    var body: some View {
        VStack(spacing: Metric.space4) {
            ZStack {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(Color.cnCard2)
                Image(systemName: "bookmark")
                    .font(.system(size: 26, weight: .regular))
                    .foregroundStyle(Color.cnInk3)
            }
            .frame(width: 64, height: 64)

            Text("还没有条目")
                .font(.cnTitle)
                .foregroundStyle(Color.cnInk)

            Text("粘贴一个链接，或从文件导入。第一条笔记就从这里开始。")
                .font(.cnChip)
                .foregroundStyle(Color.cnInk3)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 280)

            PrimaryButton(title: "导入第一条", action: onImport)
                .frame(width: 180)
                .padding(.top, Metric.space1)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, Metric.pagePad)
    }
}
