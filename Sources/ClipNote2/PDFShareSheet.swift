import SwiftUI

/// PDF 导出的分享面板。
///
/// 单独成文件不是为了整洁：详情页的 `body` 已经长到让 Swift 编译器
/// 类型推断超时（`unable to type-check this expression in reasonable time`），
/// 把这段搬出来是最小代价的解法。
struct PDFShareSheet: View {
    var url: URL
    var onDone: () -> Void

    var body: some View {
        VStack(spacing: Metric.space4) {
            Image(systemName: "doc.richtext")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(Color.cnBrand)
                .padding(.top, Metric.space5)

            Text(url.lastPathComponent)
                .font(.cnChip)
                .foregroundStyle(Color.cnInk)
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .padding(.horizontal, Metric.pagePad)

            Text("摘要、笔记、分段、书签、批注、脑图，按 A4 分页。不含封面与视频。")
                .font(.cnMeta)
                .foregroundStyle(Color.cnInk3)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, Metric.pagePad)

            ShareLink(item: url) {
                shareLabel
            }
            .padding(.horizontal, Metric.pagePad)

            Button("完成", action: onDone)
                .font(.cnChip)
                .foregroundStyle(Color.cnInk3)
                .padding(.bottom, Metric.space4)

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity)
        .background(Color.cnBg)
        .presentationDetents([.height(360)])
    }

    private var shareLabel: some View {
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
}
