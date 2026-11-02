import SwiftUI
import UIKit

/// 系统转圈。
///
/// 为什么不用自绘的 `RingSpinner`：它靠 `rotationEffect` + `repeatForever` 转，
/// 而旋转是**几何动画**——每一帧都会让上层重新计算布局并触发重绘。
/// 首页那个大转圈出现时，导航栏里的「导入」按钮会跟着每帧被重排，
/// 表现就是持续上下抽动（真机复现，而且只在「加载中」时才出现）。
///
/// `UIActivityIndicatorView` 的动画跑在图层里，不进入 SwiftUI 的布局系统，
/// 所以它转多久都不会带着邻居一起跳。
struct ActivitySpinner: UIViewRepresentable {
    var color: Color = .cnBrand
    var style: UIActivityIndicatorView.Style = .medium

    func makeUIView(context: Context) -> UIActivityIndicatorView {
        let view = UIActivityIndicatorView(style: style)
        view.color = UIColor(color)
        view.hidesWhenStopped = false
        view.startAnimating()
        return view
    }

    func updateUIView(_ view: UIActivityIndicatorView, context: Context) {
        view.color = UIColor(color)
        if !view.isAnimating {
            view.startAnimating()
        }
    }
}
