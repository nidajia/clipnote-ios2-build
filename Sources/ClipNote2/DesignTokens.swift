import SwiftUI

// MARK: - 取色

/// 取色锚点。
/// 快照测试用的是「宿主 App」环境，但 `Bundle.main` 在某些测试配置下会指向测试包，
/// 那时 `Color("bg")` 会静默解析失败（渲染成黑色）。这里固定指向组件所在的 bundle。
private final class TokenBundleAnchor {}

private let tokenBundle = Bundle(for: TokenBundleAnchor.self)

extension Color {
    init(token name: String) {
        self.init(name, bundle: tokenBundle)
    }
}

// MARK: - 颜色 Token（与 css/v7.css 同源）

extension Color {
    static let cnBg = Color(token: "bg")
    static let cnCard = Color(token: "card")
    static let cnCard2 = Color(token: "card2")
    static let cnCard3 = Color(token: "card3")

    static let cnInk = Color(token: "ink")
    static let cnInk2 = Color(token: "ink2")
    static let cnInk3 = Color(token: "ink3")

    static let cnBrand = Color(token: "brand")
    static let cnBrandPress = Color(token: "brandPress")
    static let cnBrandSoft = Color(token: "brandSoft")

    static let cnGreen = Color(token: "green")
    static let cnGreenSoft = Color(token: "greenSoft")
    static let cnRed = Color(token: "red")

    static let cnHairline = Color(token: "hairline")
    static let cnHairlineSoft = Color(token: "hairlineSoft")
}

// MARK: - 字体 Token

/// 一律用系统自带 PingFang + `relativeTo`，不打包字体文件。
/// 漏写 `relativeTo` 的 `Font.custom` 会让 Dynamic Type 整体失效——这是必须封成常量的原因。
extension Font {
    /// 28 / 34 Bold —— 首页大标题
    static let cnLargeTitle = Font.custom("PingFangSC-Semibold", size: 28, relativeTo: .largeTitle)
    /// 17 / 24 SemiBold —— 详情页标题
    static let cnTitle = Font.custom("PingFangSC-Semibold", size: 17, relativeTo: .headline)
    /// 15 / 21 SemiBold —— 列表行标题
    static let cnRowTitle = Font.custom("PingFangSC-Semibold", size: 15, relativeTo: .body)
    /// 15 / 23 Regular —— 正文
    static let cnBody = Font.custom("PingFangSC-Regular", size: 15, relativeTo: .body)
    /// 15 / 20 SemiBold —— 主按钮
    static let cnButton = Font.custom("PingFangSC-Semibold", size: 15, relativeTo: .body)
    /// 13 / 18 Medium —— Chip、小节标签
    static let cnChip = Font.custom("PingFangSC-Medium", size: 13, relativeTo: .subheadline)
    /// 12 / 17 Regular —— 元信息
    static let cnMeta = Font.custom("PingFangSC-Regular", size: 12, relativeTo: .footnote)
    /// 11 / 16 Medium —— 徽标、脚注
    static let cnCaption = Font.custom("PingFangSC-Medium", size: 11, relativeTo: .caption)
    /// 10 —— 缩略图时长（数字用 Inter，避免中文字体的等宽数字差异）
    static let cnDuration = Font.custom("Inter-Medium", size: 10, relativeTo: .caption2)
}

// MARK: - 尺寸 Token

enum Metric {
    /// 手机画框圆角（仅画廊展示用，真机不需要）
    static let radiusPhone: CGFloat = 40
    static let radiusSheet: CGFloat = 28
    static let radiusCard: CGFloat = 16
    static let radiusButton: CGFloat = 12
    static let radiusCover: CGFloat = 8

    static let pagePad: CGFloat = 20
    static let rowHeight: CGFloat = 72
    static let coverWidth: CGFloat = 100
    static let coverHeight: CGFloat = 56
    static let touch: CGFloat = 44

    static let space1: CGFloat = 4
    static let space2: CGFloat = 8
    static let space3: CGFloat = 12
    static let space4: CGFloat = 16
    static let space5: CGFloat = 20
    static let space6: CGFloat = 24
}
