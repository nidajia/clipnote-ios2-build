import SwiftUI

/// 导入面板（画布 04）
///
/// 只做两个入口：链接与本地文件。其余六个快捷入口属于第二包，
/// 提前摆上去就是点不动的死格子。
struct ImportSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var link = ""

    var body: some View {
        VStack(alignment: .leading, spacing: Metric.space3) {
            Text("导入")
                .font(.system(size: 20, weight: .bold))
                .foregroundStyle(Color.cnInk)
                .padding(.bottom, Metric.space1)

            TextField("粘贴视频链接 — B 站 / 抖音 / 小红书 / 视频号", text: $link)
                .textFieldStyle(.plain)
                .font(.cnChip)
                .foregroundStyle(Color.cnInk)
                .padding(.horizontal, 14)
                .frame(height: 46)
                .background(
                    Color.cnCard2,
                    in: RoundedRectangle(cornerRadius: Metric.radiusButton, style: .continuous)
                )

            PrimaryButton(title: "解析链接") {
                dismiss()
            }

            Text("或")
                .font(.cnCaption)
                .foregroundStyle(Color.cnInk3)
                .frame(maxWidth: .infinity)

            optionRow(symbol: "link", title: "从剪贴板读取链接")
            optionRow(symbol: "folder", title: "从文件导入视频 / 音频")

            Spacer(minLength: 0)
        }
        .padding(.horizontal, Metric.pagePad)
        .padding(.top, Metric.space2)
        .padding(.bottom, Metric.space6)
        .presentationDetents([.height(392)])
        .presentationDragIndicator(.visible)
        .presentationBackground(Color.cnCard)
    }

    private func optionRow(symbol: String, title: String) -> some View {
        HStack(spacing: Metric.space3) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(Color.cnBrand)
                .frame(width: 20)

            Text(title)
                .font(.cnChip)
                .foregroundStyle(Color.cnInk)

            Spacer(minLength: 0)

            Image(systemName: "chevron.right")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color.cnInk3)
        }
        .padding(.horizontal, 14)
        .frame(height: 52)
        .background(
            Color.cnCard2,
            in: RoundedRectangle(cornerRadius: Metric.radiusButton, style: .continuous)
        )
    }
}
