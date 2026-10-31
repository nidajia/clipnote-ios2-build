import SwiftUI

/// 「我」（画布 09）
///
/// 第一包里它不是装饰：本地没有 macOS，改完只能推 CI，
/// 没有同步入口与日志入口，出问题就没有任何现场。
///
/// 版式上刻意全部交给 `List(.insetGrouped)`：
/// 同步卡原先自绘圆角与描边，结果左右内边距和系统分组对不齐，两张卡宽度差一截。
struct MeScreen: View {
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var downloads: DownloadStore

    var body: some View {
        List {
            Section {
                syncRow
            }
            .listRowBackground(Color.cnCard)

            Section {
                settingsRow("下载与存储", storageValue)
                settingsRow("播放", "自动横屏")
                settingsRow("运行日志", "最近 0 条")
            }
            .listRowBackground(Color.cnCard)

            Section {
                Text("版本 8.0.0 (1)")
                    .font(.cnMeta)
                    .foregroundStyle(Color.cnInk3)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(Color.cnBg)
        .navigationTitle("我")
    }

    // MARK: - 同步

    /// 同步卡现在是**真的入口**：点一下重新拉库。
    /// 本地没有 macOS，装机后改不了代码，这个按钮是唯一的现场手段。
    private var syncRow: some View {
        Button {
            Task { await library.reload() }
        } label: {
            HStack(spacing: Metric.space3) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color.cnBrandSoft)
                    Image(systemName: syncIcon)
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(Color.cnBrand)
                }
                .frame(width: 34, height: 34)

                VStack(alignment: .leading, spacing: 3) {
                    Text("云端快照")
                        .font(.cnRowTitle)
                        .foregroundStyle(Color.cnInk)
                    Text(syncDetail)
                        .font(.cnMeta)
                        .foregroundStyle(isSyncFailed ? Color.cnRed : Color.cnInk3)
                        .lineLimit(2)
                }

                Spacer(minLength: 0)

                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.cnInk3)
            }
            .padding(.vertical, Metric.space2)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(library.phase == .loading)
        .accessibilityLabel("同步云端快照")
        .accessibilityValue(syncDetail)
    }

    private var isSyncFailed: Bool {
        if case .failed = library.phase { return true }
        return false
    }

    private var syncIcon: String {
        if case .failed = library.phase { return "exclamationmark.icloud" }
        return "icloud.and.arrow.down"
    }

    private var syncDetail: String {
        switch library.phase {
        case .idle:
            return "未同步"
        case .loading:
            return "正在同步…"
        case .loaded:
            // 版本号直接来自服务端，能据此判断线上代码是哪一版
            return "\(library.version) · \(library.items.count) 条"
        case .failed(let message):
            return message
        }
    }

    // MARK: - 设置行

    private var storageValue: String {
        guard downloads.downloadedCount > 0 else { return "无本地文件" }
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useMB, .useGB]
        formatter.countStyle = .file
        formatter.allowsNonnumericFormatting = false
        let size = formatter.string(fromByteCount: downloads.totalBytes)
        return "\(downloads.downloadedCount) 条 · \(size)"
    }

    private func settingsRow(_ title: String, _ value: String) -> some View {
        HStack(spacing: Metric.space2) {
            Text(title)
                .font(.cnBody)
                .foregroundStyle(Color.cnInk)
            Spacer(minLength: 0)
            Text(value)
                .font(.cnMeta)
                .foregroundStyle(Color.cnInk3)
            Image(systemName: "chevron.right")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color.cnInk3)
        }
        .frame(height: 44)
    }
}
