import SwiftUI

/// 运行日志（「我」页点进来）
///
/// 画布上没有这一屏——画布 09 只有一行「运行日志 最近 20 条」。
/// 按现有设计语言直接做：List + 等宽小字，不做卡片。
///
/// 它存在的理由写在 HANDOVER 里：「本地没有 macOS，改完只能推 CI，
/// 没有同步入口与日志入口，出问题就没有任何现场」。
struct LogScreen: View {
    @EnvironmentObject private var logs: LogStore

    @State private var isUploading = false
    @State private var message: String?
    @State private var confirmingClear = false

    var body: some View {
        List {
            if logs.entries.isEmpty {
                emptyState
            } else {
                Section {
                    ForEach(logs.newestFirst) { entry in
                        row(entry)
                    }
                } footer: {
                    Text("共 \(logs.count) 条，最多保留 200 条。错误会自动上报，信息级只在手动上报时上传。")
                        .font(.cnMeta)
                        .foregroundStyle(Color.cnInk3)
                }
            }

            if let message {
                Section {
                    Text(message)
                        .font(.cnMeta)
                        .foregroundStyle(Color.cnInk3)
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(Color.cnBg)
        .navigationTitle("运行日志")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    Task { await upload() }
                } label: {
                    if isUploading {
                        RingSpinner(size: 14, color: .cnBrand)
                    } else {
                        Text("上报")
                    }
                }
                .disabled(logs.entries.isEmpty || isUploading)
            }
            ToolbarItem(placement: .topBarLeading) {
                Button("清空") { confirmingClear = true }
                    .disabled(logs.entries.isEmpty)
            }
        }
        .confirmationDialog("清空本地日志？", isPresented: $confirmingClear, titleVisibility: .visible) {
            Button("清空", role: .destructive) {
                logs.clear()
                message = nil
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("清空后本地记录就没了，服务端已上报的还在。")
        }
    }

    // MARK: - 行

    private func row(_ entry: LogEntry) -> some View {
        HStack(alignment: .top, spacing: Metric.space3) {
            Circle()
                .fill(color(for: entry.level))
                .frame(width: 7, height: 7)
                .padding(.top, 6)

            VStack(alignment: .leading, spacing: 3) {
                Text(entry.message)
                    .font(.cnMeta)
                    .foregroundStyle(entry.level == .error ? Color.cnInk : Color.cnInk2)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: Metric.space2) {
                    Text(timeText(entry.ts))
                    Text(entry.key)
                }
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(Color.cnInk3)
            }
        }
        .padding(.vertical, 2)
        .listRowBackground(Color.cnCard)
    }

    private func color(for level: LogEntry.Level) -> Color {
        switch level {
        case .info: return .cnInk3
        case .warn: return .cnBrand
        case .error: return .cnRed
        }
    }

    private func timeText(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MM-dd HH:mm:ss"
        return formatter.string(from: date)
    }

    private var emptyState: some View {
        Section {
            VStack(spacing: Metric.space2) {
                Text("还没有日志")
                    .font(.cnChip)
                    .foregroundStyle(Color.cnInk2)
                Text("同步、播放、下载、导入出问题时，这里会有记录。")
                    .font(.cnMeta)
                    .foregroundStyle(Color.cnInk3)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, Metric.space5)
            .listRowBackground(Color.cnCard)
        }
    }

    // MARK: - 上报

    private func upload() async {
        isUploading = true
        message = nil
        let count = await logs.uploadAll()
        isUploading = false
        message = count > 0 ? "已上报 \(count) 条。" : "没有可上报的内容（或未配置服务端）。"
    }
}
