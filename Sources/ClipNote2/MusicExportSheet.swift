import SwiftUI

/// 背景音乐导出的分享面板。
///
/// 和 PDF 面板分开：图标、说明都不同，混成一个文件只会让两种导出
/// 都说不清自己是什么。音乐是「存到文件/发到别处配乐」，不是文档。
struct MusicExportSheet: View {
    var url: URL
    var onDone: () -> Void

    var body: some View {
        VStack(spacing: Metric.space4) {
            Image(systemName: "music.note")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(Color.cnBrand)
                .padding(.top, Metric.space5)

            Text(url.lastPathComponent)
                .font(.cnChip)
                .foregroundStyle(Color.cnInk)
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .padding(.horizontal, Metric.pagePad)

            Text("可存到「文件」App，或发到其它应用当配乐。")
                .font(.cnMeta)
                .foregroundStyle(Color.cnInk3)
                .multilineTextAlignment(.center)
                .padding(.horizontal, Metric.pagePad)

            ShareLink(item: url) {
                HStack(spacing: 6) {
                    Image(systemName: "square.and.arrow.up")
                        .font(.system(size: 13, weight: .semibold))
                    Text("保存 / 分享")
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

            Button("完成", action: onDone)
                .font(.cnChip)
                .foregroundStyle(Color.cnInk3)
                .padding(.bottom, Metric.space4)

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity)
        .background(Color.cnBg)
    }
}
