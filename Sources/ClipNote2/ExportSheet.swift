import SwiftUI

/// 导出面板。
///
/// 为什么单独一块、常驻可见：上一版把 PDF 按钮塞进「AI 摘要」卡片的头部，
/// 结果是**没有摘要的条目根本没有这个入口**。
/// 导出是「把一条内容带走」，它跟有没有摘要无关，不该被另一块内容的存在与否绑住。
struct ExportSheet: View {
    var hasSummary: Bool
    var onPDF: () -> Void
    var onInfographic: () -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(spacing: Metric.space3) {
                row(
                    icon: "doc.richtext",
                    title: "PDF 文档",
                    detail: "摘要、笔记、分段、书签、批注、脑图，按 A4 分页。适合打印与存档。",
                    action: {
                        dismiss()
                        // dismiss 与推 sheet 之间要留一帧，否则详情页的 sheet
                        // 还没关完就又弹一个，iOS 会吞掉后一个
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { onPDF() }
                    }
                )

                row(
                    icon: "doc.text.image",
                    title: "长图",
                    detail: "一张竖向长图，适合发微信、贴进笔记软件。",
                    isEnabled: hasSummary,
                    disabledHint: "这条还没有 AI 摘要，长图里会几乎空白。",
                    action: {
                        dismiss()
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { onInfographic() }
                    }
                )

                Spacer(minLength: 0)
            }
            .padding(Metric.pagePad)
            .background(Color.cnBg)
            .navigationTitle("导出")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("关闭") { dismiss() }
                        .font(.cnChip)
                }
            }
        }
        .presentationDetents([.height(360)])
    }

    private func row(
        icon: String, title: String, detail: String,
        isEnabled: Bool = true, disabledHint: String = "",
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: Metric.space3) {
                Image(systemName: icon)
                    .font(.system(size: 18, weight: .regular))
                    .foregroundStyle(isEnabled ? Color.cnBrand : Color.cnInk3)
                    .frame(width: 26)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.cnChip)
                        .foregroundStyle(isEnabled ? Color.cnInk : Color.cnInk3)
                    Text(isEnabled ? detail : disabledHint)
                        .font(.cnMeta)
                        .foregroundStyle(Color.cnInk3)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Color.cnInk3)
            }
            .padding(Metric.space3)
            .background(
                Color.cnCard,
                in: RoundedRectangle(cornerRadius: Metric.radiusButton, style: .continuous)
            )
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
    }
}
