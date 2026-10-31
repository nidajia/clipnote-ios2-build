import SwiftUI
import UIKit
import XCTest

/// 快照写入工具。
///
/// 约定：
/// - 产物落在仓库根的 `screenshots/`（可用 SCREENSHOT_DIR 覆盖）
/// - 同时作为 XCTAttachment 挂到结果包里，便于在 xcresult 里直接看
@MainActor
enum SnapshotSupport {

    static var outputDir: URL {
        if let custom = ProcessInfo.processInfo.environment["SCREENSHOT_DIR"], !custom.isEmpty {
            return URL(fileURLWithPath: custom, isDirectory: true)
        }
        return URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // ClipNote2Tests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // 仓库根
            .appendingPathComponent("screenshots", isDirectory: true)
    }

    /// - Parameter size: 传 nil 表示按内容自适应高度（画廊用）；
    ///   传具体尺寸用于整屏渲染（TabView / NavigationStack 需要明确提议尺寸）。
    static func write<V: View>(
        _ view: V,
        name: String,
        scheme: ColorScheme,
        size: CGSize? = nil
    ) throws {
        let base = view
            .environment(\.colorScheme, scheme)
            .environment(\.dynamicTypeSize, .large)

        let sized: AnyView
        if let size {
            sized = AnyView(base.frame(width: size.width, height: size.height))
        } else {
            sized = AnyView(base)
        }

        let renderer = ImageRenderer(content: sized)
        renderer.scale = 2
        renderer.isOpaque = true

        guard let image = renderer.uiImage else {
            XCTFail("ImageRenderer 没有产出图像：\(name)")
            return
        }
        guard let data = image.pngData() else {
            XCTFail("PNG 编码失败：\(name)")
            return
        }

        // 空白图通常只有几百字节；直接判失败，避免 CI 上传一张黑图却显示绿灯
        XCTAssertGreaterThan(data.count, 8_000, "截图过小，可能渲染成了空白：\(name)")

        try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
        try data.write(to: outputDir.appendingPathComponent("\(name).png"))

        XCTContext.runActivity(named: name) { activity in
            let attachment = XCTAttachment(image: image)
            attachment.name = name
            attachment.lifetime = .keepAlways
            activity.add(attachment)
        }
    }

    /// iPhone 15/16 的逻辑尺寸，与画布 390 × 844 对齐
    static let phone = CGSize(width: 390, height: 844)
}
