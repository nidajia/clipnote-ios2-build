import SwiftUI

// MARK: - 列表行数据
//
// 这一阶段还没有网络层，先用本地模型喂画廊与快照。
// 注意：它不承担任何「字段映射」职责——字段对应关系由服务端接口决定，
// 客户端不得在内置代码里复刻（见 HANDOVER 硬约束 5）。

struct ItemRowModel: Identifiable {
    let id = UUID()
    var title: String
    var platform: String
    var author: String
    var duration: String
    var isDownloaded: Bool
    var coverTop: Color
    var coverBottom: Color

    var metaLine: String { "\(platform) · \(author)" }
}

// MARK: - 缩略图

struct Thumbnail: View {
    var top: Color
    var bottom: Color
    var duration: String

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            LinearGradient(
                colors: [top, bottom],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

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
    var model: ItemRowModel

    var body: some View {
        HStack(spacing: Metric.space3) {
            Thumbnail(top: model.coverTop, bottom: model.coverBottom, duration: model.duration)

            VStack(alignment: .leading, spacing: 5) {
                Text(model.title)
                    .font(.cnRowTitle)
                    .foregroundStyle(Color.cnInk)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    // 没有这一句，长标题不会换行，而是把右侧内容顶出可视区
                    .frame(maxWidth: .infinity, alignment: .leading)

                HStack(spacing: Metric.space2) {
                    Text(model.metaLine)
                        .font(.cnMeta)
                        .foregroundStyle(Color.cnInk3)
                        .lineLimit(1)

                    if model.isDownloaded {
                        DownloadBadge()
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(height: Metric.rowHeight)
        .contentShape(Rectangle())
        // 放进 List 时生效；在画廊里是空操作
        .listRowInsets(EdgeInsets(
            top: 0,
            leading: Metric.pagePad,
            bottom: 0,
            trailing: Metric.pagePad
        ))
        .listRowSeparator(.hidden)
        .listRowBackground(Color.cnBg)
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

    var body: some View {
        Circle()
            .trim(from: 0, to: 0.72)
            .stroke(color, style: StrokeStyle(lineWidth: 2, lineCap: .round))
            .rotationEffect(.degrees(-90))
            .frame(width: size, height: size)
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
