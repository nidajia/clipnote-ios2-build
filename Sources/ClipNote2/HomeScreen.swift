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
    @State private var filter: HomeFilter = .all
    @State private var showImport = false
    @State private var selected: Item?

    /// `initialSelection` 只给截图用：让详情页以「被 push 进去」的形态出现，
    /// 否则它会是导航栈的根，截图上没有返回按钮。
    /// `detailPrepare` 同理：让「已取到播放地址」这一态能被拍下来。
    init(
        initialSelection: Item? = nil,
        detailPrepare: DetailScreen.PrepareState? = nil
    ) {
        _selected = State(initialValue: initialSelection)
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
        return list.filter {
            $0.title.localizedCaseInsensitiveContains(q)
                || $0.metaLine.localizedCaseInsensitiveContains(q)
        }
    }

    var body: some View {
        content
            .background(Color.cnBg)
            .navigationTitle("片记")
            .navigationBarTitleDisplayMode(.large)
            .searchable(
                text: $query,
                placement: .navigationBarDrawer(displayMode: .always),
                prompt: "搜索标题、要点、标签"
            )
            .safeAreaInset(edge: .top, spacing: 0) { filterBar }
            .navigationDestination(item: $selected) { item in
                DetailScreen(item: item, initialPrepare: detailPrepare)
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showImport = true
                    } label: {
                        importLabel
                    }
                    .buttonStyle(.plain)
                }
            }
            .sheet(isPresented: $showImport) {
                ImportSheet()
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
                    selected = item
                } label: {
                    ItemRow(model: item, isDownloaded: downloads.isDownloaded(item.id))
                }
                .buttonStyle(.plain)
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
            // 行本身不再硬关分隔线，由这里统一定义颜色
            .listRowSeparatorTint(Color.cnCard2)
            .listRowSpacing(0)
        }
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
            RingSpinner(size: 28, color: .cnBrand)
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
