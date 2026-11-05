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
    @EnvironmentObject private var logs: LogStore

    @State private var exporting = false
    @State private var exportURL: URL?

    var body: some View {
        List {
            Section {
                syncRow
            }
            .listRowBackground(Color.cnCard)

            Section {
                // 这两行只显示信息，点不动——所以不给箭头。
                // 带箭头却点不开，比没有箭头更让人困惑。
                settingsRow("下载与存储", storageValue, showsChevron: false)
                settingsRow("播放", "自动横屏", showsChevron: false)
                NavigationLink {
                    AISettingsScreen()
                } label: {
                    settingsRow("AI 摘要", AIConfigStore.load().isConfigured ? "已配置" : "未配置",
                                showsChevron: false)
                }
                NavigationLink {
                    TagsScreen()
                } label: {
                    settingsRow("标签", tagText, showsChevron: false)
                }
                NavigationLink {
                    TrashScreen()
                } label: {
                    settingsRow("回收站", trashText, showsChevron: false)
                }
                Button {
                    Task { await prepareExport() }
                } label: {
                    settingsRow("导出全部笔记", exporting ? "生成中…" : "Markdown",
                                showsChevron: false)
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.cnInk)
                NavigationLink {
                    LogScreen()
                } label: {
                    // 不加自带 chevron：NavigationLink 已经给了一个
                    settingsRow("运行日志", logCountText, showsChevron: false)
                }
            }
            .listRowBackground(Color.cnCard)

            Section {
                Text(footer)
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
        .sheet(isPresented: Binding(
            get: { exportURL != nil },
            set: { if !$0 { exportURL = nil } }
        )) {
            if let exportURL {
                exportSheet(exportURL)
            }
        }
    }

    /// 导出完成后只有一件事可做：把它分享出去（存文件、发微信、存笔记软件）。
    private func exportSheet(_ url: URL) -> some View {
        VStack(spacing: Metric.space4) {
            Image(systemName: "doc.text")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(Color.cnBrand)
                .padding(.top, Metric.space5)

            Text(url.lastPathComponent)
                .font(.cnChip)
                .foregroundStyle(Color.cnInk)

            Text("共 \(library.items.count) 条。摘要是 AI 产的、笔记和书签是你写的，文件里已分别标注。")
                .font(.cnMeta)
                .foregroundStyle(Color.cnInk3)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, Metric.pagePad)

            ShareLink(item: url) {
                HStack(spacing: 6) {
                    Image(systemName: "square.and.arrow.up")
                        .font(.system(size: 13, weight: .semibold))
                    Text("分享 / 存为文件")
                        .font(.cnButton)
                }
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .frame(height: 48)
                .background(
                    Color.cnBrand,
                    in: RoundedRectangle(cornerRadius: Metric.radiusButton, style: .continuous)
                )
            }
            .padding(.horizontal, Metric.pagePad)

            Button("完成") { exportURL = nil }
                .font(.cnChip)
                .foregroundStyle(Color.cnInk3)
                .padding(.bottom, Metric.space4)

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity)
        .background(Color.cnBg)
        .presentationDetents([.height(360)])
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
            return "\(library.items.count) 条 · 已是最新"
        case .failed(let message):
            return message
        }
    }

    /// 导出全库。失败只可能是「临时目录写不进去」，那种情况给一句话就够。
    private func prepareExport() async {
        guard !exporting, !library.items.isEmpty else { return }
        exporting = true
        defer { exporting = false }
        exportURL = LibraryExporter.write(items: library.items)
        logs.info("export.built", "导出全库为 Markdown", meta: [
            "items": String(library.items.count),
            "ok": exportURL == nil ? "0" : "1",
        ])
    }

    // MARK: - 设置行

    /// 库版本号对用户没意义，但对排障有用：拉到的快照是不是最新、线上是哪一版，
    /// 都看这一串。所以放脚注，不占主视觉。
    private var footer: String {
        let base = "版本 \(AppVersion.text)"
        return library.version.isEmpty ? base : "\(base) · \(library.version)"
    }

    private var storageValue: String {
        guard downloads.downloadedCount > 0 else { return "无本地文件" }
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useMB, .useGB]
        formatter.countStyle = .file
        formatter.allowsNonnumericFormatting = false
        let size = formatter.string(fromByteCount: downloads.totalBytes)
        return "\(downloads.downloadedCount) 条 · \(size)"
    }

    private var trashText: String {
        library.trashCount > 0 ? "\(library.trashCount) 条" : "空"
    }

    /// 和标签页用同一个聚合函数，免得「我」页显示 8 个、点进去只有 7 个
    private var tagText: String {
        let count = TagsScreen.aggregate(library.items).count
        return count > 0 ? "\(count) 个分类" : "暂无"
    }

    private var logCountText: String {
        guard logs.count > 0 else { return "暂无记录" }
        return logs.errorCount > 0 ? "\(logs.count) 条 · \(logs.errorCount) 条错误" : "\(logs.count) 条"
    }

    private func settingsRow(_ title: String, _ value: String, showsChevron: Bool = true) -> some View {
        HStack(spacing: Metric.space2) {
            Text(title)
                .font(.cnBody)
                .foregroundStyle(Color.cnInk)
            Spacer(minLength: 0)
            Text(value)
                .font(.cnMeta)
                .foregroundStyle(Color.cnInk3)
            if showsChevron {
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.cnInk3)
            }
        }
        .frame(height: 44)
    }
}
