import SwiftUI

/// 回收站
///
/// 删除是软删：条目打上 `deletedAt` 标记，从列表消失但还在快照里。
/// 硬删之后想恢复只能靠用户重新导入，而那条内容可能已经找不回来了。
///
/// 这里也是唯一给出「彻底删除」的地方——不可恢复的操作不该藏在主列表里。
struct TrashScreen: View {
    /// 只给截图用：离线模式没有服务端，直接喂数据。
    /// 正常路径一律 nil，由 `load()` 去取。
    var previewItems: [APILibraryItem]? = nil

    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var downloads: DownloadStore

    @State private var items: [APILibraryItem] = []
    @State private var loading = true
    @State private var errorMessage: String?

    @State private var purgeTarget: APILibraryItem?
    @State private var showPurgeConfirm = false

    var body: some View {
        List {
            if loading {
                Section {
                    HStack(spacing: Metric.space2) {
                        RingSpinner(size: 16, color: .cnBrand)
                        Text("正在读取…")
                            .font(.cnMeta)
                            .foregroundStyle(Color.cnInk3)
                    }
                    .listRowBackground(Color.cnCard)
                }
            } else if let errorMessage {
                Section {
                    Text(errorMessage)
                        .font(.cnMeta)
                        .foregroundStyle(Color.cnRed)
                        .listRowBackground(Color.cnCard)
                }
            } else if items.isEmpty {
                emptyState
            } else {
                Section {
                    ForEach(items, id: \.id) { api in
                        row(api)
                    }
                } footer: {
                    Text("删除的条目会留在这里，可以恢复。彻底删除后不可恢复。")
                        .font(.cnMeta)
                        .foregroundStyle(Color.cnInk3)
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(Color.cnBg)
        .navigationTitle("回收站")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            if let previewItems {
                items = previewItems
                loading = false
                return
            }
            await load()
        }
        .refreshable { await load() }
        .confirmationDialog(
            "彻底删除？",
            isPresented: $showPurgeConfirm,
            titleVisibility: .visible,
            presenting: purgeTarget
        ) { target in
            Button("彻底删除", role: .destructive) {
                Task { await purge(target) }
            }
            Button("取消", role: .cancel) {}
        } message: { target in
            Text("「\(target.title)」将从云端与本机一起移除，无法恢复。")
        }
    }

    // MARK: - 行

    private func row(_ api: APILibraryItem) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(api.title)
                .font(.cnRowTitle)
                .foregroundStyle(Color.cnInk)
                .lineLimit(2)

            Text(api.metaLine)
                .font(.cnMeta)
                .foregroundStyle(Color.cnInk3)
                .lineLimit(1)

            // 单独一行：和 meta 挤在一起会读成「平台 · 作者 删除了」一句话
            Text(deletedText(api.deletedAt))
                .font(.cnCaption)
                .foregroundStyle(Color.cnInk3)
        }
        .padding(.vertical, 2)
        .listRowBackground(Color.cnCard)
        // 恢复放左边、彻底删除放右边：破坏性操作在右侧，与系统习惯一致
        .swipeActions(edge: .leading, allowsFullSwipe: true) {
            Button {
                Task { await restore(api) }
            } label: {
                Label("恢复", systemImage: "arrow.uturn.backward")
            }
            .tint(Color.cnBrand)
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button(role: .destructive) {
                purgeTarget = api
                showPurgeConfirm = true
            } label: {
                Label("彻底删除", systemImage: "trash.slash")
            }
        }
    }

    private var emptyState: some View {
        Section {
            VStack(spacing: Metric.space2) {
                Image(systemName: "trash")
                    .font(.system(size: 22, weight: .regular))
                    .foregroundStyle(Color.cnInk3)
                Text("回收站是空的")
                    .font(.cnChip)
                    .foregroundStyle(Color.cnInk2)
                Text("在列表里左滑删除的条目会出现在这里。")
                    .font(.cnMeta)
                    .foregroundStyle(Color.cnInk3)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, Metric.space5)
            .listRowBackground(Color.cnCard)
        }
    }

    private func deletedText(_ ms: Int?) -> String {
        guard let ms, ms > 0 else { return "" }
        let date = Date(timeIntervalSince1970: TimeInterval(ms) / 1000)
        let formatter = DateFormatter()
        formatter.dateFormat = "MM-dd HH:mm 删除"
        return formatter.string(from: date)
    }

    // MARK: - 动作

    private func load() async {
        do {
            items = try await library.loadTrash()
            errorMessage = nil
        } catch let failure as ClipNoteClient.Failure {
            errorMessage = failure.displayMessage
        } catch {
            errorMessage = "取回收站失败，请稍后重试。"
        }
        loading = false
    }

    private func restore(_ api: APILibraryItem) async {
        await library.restore(id: api.id)
        await load()
    }

    /// 彻底删除：云端移除 + 本地文件清掉。
    ///
    /// 顺序不能反：服务端失败时本地文件要还在，否则会出现
    /// 「条目还在列表里但文件没了」——点开播不了，用户不会理解为什么。
    private func purge(_ api: APILibraryItem) async {
        let ok = await library.purge(id: api.id)
        if ok {
            downloads.removeLocalFile(api.id)
        }
        await load()
    }
}
