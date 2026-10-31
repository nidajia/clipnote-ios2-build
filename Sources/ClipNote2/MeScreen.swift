import SwiftUI

/// 「我」（画布 09）
///
/// 第一包里它不是装饰：本地没有 macOS，改完只能推 CI，
/// 没有同步入口与日志入口，出问题就没有任何现场。
struct MeScreen: View {
    var body: some View {
        List {
            Section {
                syncCard
                    .listRowInsets(EdgeInsets(
                        top: Metric.space2,
                        leading: Metric.pagePad,
                        bottom: Metric.space2,
                        trailing: Metric.pagePad
                    ))
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            }

            Section {
                settingsRow("下载与存储", "—")
                settingsRow("播放", "自动横屏")
                settingsRow("运行日志", "最近 0 条")
            }
            .listRowBackground(Color.cnCard)

            Section {
                Text("片记 8.0.0 (1) · Bundle 已更换，与旧版并存")
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

    private var syncCard: some View {
        HStack(spacing: Metric.space3) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.cnBrandSoft)
                Image(systemName: "icloud.and.arrow.down")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(Color.cnBrand)
            }
            .frame(width: 34, height: 34)

            VStack(alignment: .leading, spacing: 3) {
                Text("云端快照")
                    .font(.cnRowTitle)
                    .foregroundStyle(Color.cnInk)
                Text("未连接 · 等待接入同步接口")
                    .font(.cnMeta)
                    .foregroundStyle(Color.cnInk3)
            }

            Spacer(minLength: 0)
        }
        .padding(Metric.space4)
        .background(
            Color.cnCard,
            in: RoundedRectangle(cornerRadius: Metric.radiusCard, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Metric.radiusCard, style: .continuous)
                .strokeBorder(Color.cnHairline, lineWidth: 1)
        )
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
