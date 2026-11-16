import SwiftUI

/// 下载与存储：已下载哪些、各占多大、能删。
///
/// 之前这一行在「我」里只是一串文字（`3 条 · 120 MB`），点不动。
/// 结果是：用户知道有东西占着空间，却没法知道占了什么、更没法清。
/// 离线能力要能用，这一页必须先存在——否则「我下载了什么」没有答案。
struct DownloadsScreen: View {
    @EnvironmentObject private var downloads: DownloadStore
    @EnvironmentObject private var library: LibraryStore

    /// 已下载的条目，按下载时间倒序（最近下载的在上面）。
    private var rows: [(item: Item, record: DownloadRecord)] {
        library.items
            .compactMap { item in
                guard let record = downloads.records[item.id] else { return nil }
                return (item, record)
            }
            .sorted { $0.1.finishedAt > $1.1.finishedAt }
    }

    private var totalText: String {
        let bytes = rows.reduce(Int64(0)) { $0 + $1.record.byteCount }
        guard bytes > 0 else { return "无本地文件" }
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useMB, .useGB]
        formatter.countStyle = .file
        formatter.allowsNonnumericFormatting = false
        return "\(rows.count) 条 · \(formatter.string(fromByteCount: bytes))"
    }

    var body: some View {
        List {
            if rows.isEmpty {
                Section {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("还没有下载任何条目")
                            .font(.cnBody)
                            .foregroundStyle(Color.cnInk)
                        Text("在详情页点「下载」会把视频存到本机，之后没有网络也能看。")
                            .font(.cnCaption)
                            .foregroundStyle(Color.cnInk3)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.vertical, 6)
                }
                .listRowBackground(Color.cnCard)
            } else {
                Section {
                    ForEach(rows, id: \.item.id) { row in
                        cell(row.item, row.record)
                            .listRowBackground(Color.cnCard)
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                Button(role: .destructive) {
                                    downloads.removeLocalFile(row.item.id)
                                } label: {
                                    Label("删除", systemImage: "trash")
                                }
                            }
                    }
                } header: {
                    Text(totalText)
                } footer: {
                    // 说清楚「删文件」和「删条目」不是一件事，否则用户不敢点。
                    Text("左滑删除本地文件，条目本身和笔记都还在；想彻底删除请到首页左滑那条。")
                        .font(.cnCaption)
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(Color.cnBg)
        .navigationTitle("下载与存储")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func cell(_ item: Item, _ record: DownloadRecord) -> some View {
        HStack(spacing: Metric.space3) {
            VStack(alignment: .leading, spacing: 3) {
                Text(item.title)
                    .font(.cnBody)
                    .foregroundStyle(Color.cnInk)
                    .lineLimit(2)
                HStack(spacing: 6) {
                    Text(Self.size(record.byteCount))
                        .font(.cnCaption)
                        .foregroundStyle(Color.cnInk3)
                    Text("·")
                        .font(.cnCaption)
                        .foregroundStyle(Color.cnInk3)
                    Text(Self.day(record.finishedAt))
                        .font(.cnCaption)
                        .foregroundStyle(Color.cnInk3)
                    if !item.note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Text("· 有笔记")
                            .font(.cnCaption)
                            .foregroundStyle(Color.cnBrand)
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
        .contextMenu {
            Button(role: .destructive) {
                downloads.removeLocalFile(item.id)
            } label: {
                Label("删除本地文件", systemImage: "trash")
            }
        }
    }

    private static func size(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useMB, .useGB]
        formatter.countStyle = .file
        formatter.allowsNonnumericFormatting = false
        return formatter.string(fromByteCount: bytes)
    }

    private static func day(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "M 月 d 日"
        return formatter.string(from: date)
    }
}
