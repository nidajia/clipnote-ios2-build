import SwiftUI

// MARK: - 缩略图

struct Thumbnail: View {
    var url: URL?
    var top: Color
    var bottom: Color
    var duration: String

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            // 占位渐变永远在底层：图没加载出来、加载失败、离线，
            // 都会落在这层上，不会出现一块空白。
            LinearGradient(
                colors: [top, bottom],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            if let url {
                AsyncImage(url: url, transaction: Transaction(animation: nil)) { phase in
                    if case .success(let image) = phase {
                        image
                            .resizable()
                            .scaledToFill()
                    }
                }
            }

            if !duration.isEmpty {
                Text(duration)
                    .font(.cnDuration)
                    .foregroundStyle(.white)
                    .padding(.horizontal, Metric.space1)
                    .padding(.vertical, 1.5)
                    .background(
                        Color.black.opacity(0.72),
                        in: RoundedRectangle(cornerRadius: 4, style: .continuous)
                    )
                    .padding(Metric.space1)
            }
        }
        .frame(width: Metric.coverWidth, height: Metric.coverHeight)
        .clipShape(RoundedRectangle(cornerRadius: Metric.radiusCover, style: .continuous))
        .accessibilityHidden(true)
    }
}

// MARK: - 已下载徽标

struct DownloadBadge: View {
    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: "checkmark")
                .font(.system(size: 8, weight: .bold))
            Text("已下载")
                .font(.cnCaption)
        }
        .foregroundStyle(Color.cnGreen)
        .padding(.horizontal, 5)
        .padding(.vertical, 1.5)
        .background(
            Color.cnGreenSoft,
            in: RoundedRectangle(cornerRadius: 4, style: .continuous)
        )
        // 状态必须有可见文字，不能只靠颜色
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("已下载")
    }
}

// MARK: - 条目行

struct ItemRow: View {
    var model: Item
    /// 由 `DownloadStore` 传入，行内不自己判断。
    /// 上一版这里读的是 `Item.isDownloaded`（演示数据），和详情页各说各话。
    var isDownloaded: Bool = false
    /// 已分区时显示标记。`nil` 不画任何东西：未分区不该占一个「无」字的位置，
    /// 找未分区的条目请用筛选条上那一条。
    var section: LibrarySection? = nil
    /// 覆盖 `metaLine`。笔记要在这里带上「修改 11-10 23:40」，
    /// 而时间不该塞进 `Item`——它是展示细节，不是数据。
    var subtitle: String? = nil

    var body: some View {
        HStack(spacing: Metric.space3) {
            Thumbnail(
                url: model.coverURL,
                top: model.coverTop,
                bottom: model.coverBottom,
                duration: model.durationText
            )

            VStack(alignment: .leading, spacing: 5) {
                Text(model.title)
                    .font(.cnRowTitle)
                    .foregroundStyle(Color.cnInk)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    // 没有这一句，长标题不会换行，而是把右侧内容顶出可视区
                    .frame(maxWidth: .infinity, alignment: .leading)

                HStack(spacing: Metric.space2) {
                    Text(subtitle ?? model.metaLine)
                        .font(.cnMeta)
                        .foregroundStyle(Color.cnInk3)
                        .lineLimit(1)

                    if isDownloaded {
                        DownloadBadge()
                    }

                    // 分区放最后：它是「我把它放哪了」，不是内容属性，
                    // 排在作者、时长后面读起来才顺。
                    if let section {
                        SectionBadge(section: section)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(height: Metric.rowHeight)
        .contentShape(Rectangle())
        // 行内边距与背景交给调用方（List 的直接子视图）设置：
        // `listRowInsets` 必须挂在行根上，挂在 label 内部会被忽略。
        .accessibilityElement(children: .combine)
    }
}

// MARK: - 主按钮

struct PrimaryButton: View {
    var title: String
    var isEnabled: Bool = true
    var isLoading: Bool = false
    var action: () -> Void = {}

    @Environment(\.colorScheme) private var scheme

    /// 深色下 brand 被提亮到 #6B8CFF，白字对比只有约 2.4:1，必须改墨色字
    private var labelColor: Color { scheme == .dark ? .cnBg : .white }

    var body: some View {
        Button(action: action) {
            HStack(spacing: Metric.space2) {
                if isLoading {
                    RingSpinner(color: labelColor)
                }
                Text(title)
                    .font(.cnButton)
            }
            .foregroundStyle(labelColor)
            .frame(maxWidth: .infinity)
            .frame(height: 48)
            .background(
                Color.cnBrand,
                in: RoundedRectangle(cornerRadius: Metric.radiusButton, style: .continuous)
            )
        }
        .buttonStyle(PressDimStyle())
        .disabled(!isEnabled || isLoading)
        .opacity(isEnabled ? 1 : 0.42)
    }
}

/// 按压反馈只降不透明度，不改变尺寸，避免行内跳动
struct PressDimStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.88 : 1)
    }
}

// MARK: - 加载指示

/// 纯 Shape 画的环，不用 `ProgressView`。
///
/// `ImageRenderer` 无法光栅化 UIKit 的 `UIActivityIndicatorView`，
/// 截出来会变成一个橙色占位方块——CI 截图就失去了证据价值。
/// 这里固定角度，保证每次快照可比；真机若要转起来，
/// 用 `TimelineView` 驱动 `rotationEffect`，但那样 CI 截图不再可复现，
/// 需要另开一条「仅动效」的验证路径。
struct RingSpinner: View {
    var size: CGFloat = 16
    var color: Color

    @State private var spinning = false

    var body: some View {
        Circle()
            .trim(from: 0, to: 0.72)
            .stroke(color, style: StrokeStyle(lineWidth: 2, lineCap: .round))
            .rotationEffect(.degrees(spinning ? 360 : -90))
            .frame(width: size, height: size)
            // 之前它是个**不会转**的圆弧：截图里像加载中，真机上就是个卡住的圈。
            // 一个不动的加载指示器比没有更糟——用户会以为界面死了。
            .onAppear {
                withAnimation(.linear(duration: 0.9).repeatForever(autoreverses: false)) {
                    spinning = true
                }
            }
            .accessibilityHidden(true)
    }
}

// MARK: - 筛选 Chip

struct FilterChip: View {
    var title: String
    var isSelected: Bool

    @Environment(\.colorScheme) private var scheme

    /// 与主按钮同一条规则：深色下 brand 变亮，白字对比不足，必须换墨色字
    private var selectedLabel: Color { scheme == .dark ? .cnBg : .white }

    var body: some View {
        Text(title)
            .font(.cnChip)
            .foregroundStyle(isSelected ? selectedLabel : Color.cnInk2)
            .padding(.horizontal, Metric.space3)
            .frame(height: 30)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isSelected ? Color.cnBrand : Color.cnCard)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(isSelected ? Color.clear : Color.cnHairline, lineWidth: 1)
            )
            .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
