import XCTest
import SwiftUI
import UIKit
@testable import ClipNote2

/// 把组件画廊渲染成 PNG。
///
/// 这是「不需要人工装机也能看到界面」这条验收的最小实现：
/// 在模拟器里跑一次单元测试，把浅色 / 深色两张图写到仓库的 screenshots/ 下，
/// 再作为 artifact 上传。
@MainActor
final class GallerySnapshotTests: XCTestCase {

    /// 产物目录：默认落在仓库根的 screenshots/，可用 SCREENSHOT_DIR 覆盖
    private var outputDir: URL {
        if let custom = ProcessInfo.processInfo.environment["SCREENSHOT_DIR"], !custom.isEmpty {
            return URL(fileURLWithPath: custom, isDirectory: true)
        }
        return URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // ClipNote2Tests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // 仓库根
            .appendingPathComponent("screenshots", isDirectory: true)
    }

    func testGalleryLight() throws {
        try render(scheme: .light, name: "gallery-light")
    }

    func testGalleryDark() throws {
        try render(scheme: .dark, name: "gallery-dark")
    }

    private func render(scheme: ColorScheme, name: String) throws {
        let view = ComponentGallery()
            .environment(\.colorScheme, scheme)
            .environment(\.dynamicTypeSize, .large)

        let renderer = ImageRenderer(content: view)
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

        // 空白图通常只有几百字节，这里直接判失败，避免 CI 上传一张黑图却显示绿灯
        XCTAssertGreaterThan(data.count, 8_000, "截图过小，可能渲染成了空白：\(name)")

        try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
        try data.write(to: outputDir.appendingPathComponent("\(name).png"))

        let attachment = XCTAttachment(image: image)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
