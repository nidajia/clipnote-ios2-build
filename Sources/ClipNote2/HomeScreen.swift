import SwiftUI

/// 首页筛选。值即展示文案，避免再造一层映射。
enum HomeFilter: String, CaseIterable, Identifiable {
    case all = "全部"
    case video = "视频"
    case note = "笔记"
    case downloaded = "已下载"

    var id: String { rawValue }
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
    @State private var selected: Item?
    @State private var toast: String?

    /// `initialSelection` 只给截图用：让详情页以「被 push 进去」的形态出现，
    /// 否则它会是导航栈的根，截图上没有返回按钮。
    /// `detailPrepare` 同理：让「已取到播放地址」这一态能被拍下来。
    init(
        initialSelection: Item? = nil,
        detailPrepare: DetailScreen.PrepareState? = nil,
        showsImport: Bool = false,
        previewSelecting: Bool = false
    ) {
        _selected = State(initialValue: initialSelection)
        _showImport = State(initialValue: showsImport)
        _selecting = State(initialValue: previewSelecting)
        self.detailPrepare = detailPrepare
    }

    private let detailPrepare: DetailScreen.PrepareState?

    private var items: [Item] { library.items }

    private var filtered: [Item] {
        var list = items
        switch filter {
        case .all: break
        case .video: list = list.filter { $0.kind == .video }
        case .note: list = list.filter { $0.kind == .note }
        case .downloaded: list = list.filter { downloads.isDownloaded($0.id) }
        }
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return list }
        // 交给 LibrarySearch：字段清单和输入框文案必须在一个地方，
        // 分开写就会出现「写着能搜标签，实际搜不到」。
        return list.filter {
            LibrarySearch.matches($0, query: q)
                || !TranscriptIndex.hits(in: transcripts[$0.id] ?? [], query: q, limit: 3).isEmpty
        }
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
                        Button {
                            showImport = true
                        } label: {
                            importLabel
                        }
                        .buttonStyle(.plain)
                    }
                }
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
                ImportSheet()
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
        if filtered.isEmpty {
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
                        selected = item
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
                            ItemRow(model: item, isDownloaded: downloads.isDownloaded(item.id))
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
                            showToast(ok ? "已移到回收站" : "删除失败，请重试")
                        }
                    } label: {
                        Label("删除", systemImage: "trash")
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
        showToast("已把 \(count) 条移到回收站")
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
        }
        .background(Color.cnBg)
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.cnInk3)

            TextField("搜索标题、作者、标签、笔记", text: $query)
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

    /// 钉在顶部的筛选条，不随列表滚动
    private var filterBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Metric.space2) {
                ForEach(HomeFilter.allCases) { item in
                    Button {
                        filter = item
                    } label: {
                        FilterChip(title: item.rawValue, isSelected: item == filter)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, Metric.pagePad)
            .padding(.vertical, Metric.space2)
        }
        .background(Color.cnBg)
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
