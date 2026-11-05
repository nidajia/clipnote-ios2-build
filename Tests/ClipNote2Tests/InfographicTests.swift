import XCTest
import SwiftUI
import UIKit
@testable import ClipNote2

/// 信息图（长图）的验证。
///
/// 这里验的不是「编译过」——那件事已经让这个项目返工过。验的是三件可判定的事：
/// 1. 线上那条 `ImageRenderer` 路径真的产出了位图，宽度正好是 390×3；
/// 2. 高度随内容增长（有分段时明显高于一张方图），即「长图」名副其实；
/// 3. 只有摘要、没有分段时也不会散架，只是更短。
@MainActor
final class InfographicTests: XCTestCase {

    /// 固定日期：截图要可复现，不能让「今天」变成图上唯一的变量
    private let fixedDate = Date(timeIntervalSince1970: 1_793_260_800)

    private func sampleItem(segments: Int = 9) -> Item {
        Item(
            id: "seed0000000001",
            title: "互联网泡沫重演？AI 泡沫为何比 2000 年更凶险",
            metaLine: "B 站 · 幽州-节度使",
            durationText: "16:57",
            durationSeconds: 1017,
            summary: "感谢索导的配音",
            aiSummary: "这条片子讨论的是：现在的 AI 热潮与 2000 年互联网泡沫，究竟哪里像、哪里不一样。"
                + "结论不是「一定会崩」，而是估值与收入之间的缺口比当年更难解释。",
            keyPoints: [
                "估值跑在收入前面，且集中在少数几家公司",
                "与 2000 年不同：这次的基础设施是真实在用的",
                "资本开支的回收周期比市场预期更长",
            ],
            labels: ["AI", "投资", "互联网史"],
            segments: Array(SnapshotRoot.sampleSegments.prefix(segments)),
            author: "幽州-节度使",
            platform: "bilibili"
        )
    }

    private func pixels(_ image: UIImage) -> CGSize {
        CGSize(width: image.size.width * image.scale,
               height: image.size.height * image.scale)
    }

    // MARK: - 缩放策略

    func testScaleShortContentIsCrisp() {
        XCTAssertEqual(InfographicRenderer.scale(forHeight: 800), 3, accuracy: 0.001)
    }

    func testScaleDropsForLongContent() {
        // 30 段约 3000pt 高，3x 会超像素预算，必须降下来
        let scale = InfographicRenderer.scale(forHeight: 3000)
        XCTAssertLessThan(scale, 3)
        XCTAssertGreaterThanOrEqual(scale, 1.5)
        let pixels = InfographicCard.width * 3000 * scale * scale
        XCTAssertLessThanOrEqual(pixels, InfographicRenderer.pixelBudget * 1.01)
    }

    func testScaleNeverBlursBelowFloor() {
        XCTAssertEqual(InfographicRenderer.scale(forHeight: 100_000), 1.5, accuracy: 0.001)
    }

    // MARK: - 生产线

    func testRendererProducesLongImage() throws {
        let item = sampleItem()
        let image = try XCTUnwrap(
            InfographicRenderer.makeImage(item, generatedAt: fixedDate),
            "ImageRenderer 没有产出图像——排版里有不可渲染的容器（List/TabView/ScrollView）？"
        )

        let size = pixels(image)
        // scale 现在随内容高度变化，宽度断言应跟实际选中的 scale 走；
        // 要验的是「宽度锁在版心、没有横向留白」，不是某个固定倍数。
        XCTAssertEqual(size.width, InfographicCard.width * image.scale,
                       accuracy: 1, "宽度必须锁在版心宽度，否则分享出去的图会被缩放得糊")
        XCTAssertGreaterThan(size.height, size.width * 1.2,
                             "9 段内容排下来还不到 1.2 倍宽，说明高度塌了或分段没渲染")

        let data = try XCTUnwrap(image.pngData())
        XCTAssertGreaterThan(data.count, 40_000,
                             "PNG 过小，多半只画出了背景")
    }

    /// 摘要 + 9 段的整张长图，直接落进 screenshots/ 供人工核对。
    func testLongImageSnapshot() throws {
        try SnapshotSupport.write(
            InfographicCard(item: sampleItem(), generatedAt: fixedDate),
            name: "infographic-long",
            scheme: .light
        )
    }

    // MARK: - 边界

    func testWithoutSegmentsIsShorterButStillRenders() throws {
        let withAll = try XCTUnwrap(
            InfographicRenderer.makeImage(sampleItem(), generatedAt: fixedDate)
        )
        let summaryOnly = try XCTUnwrap(
            InfographicRenderer.makeImage(sampleItem(segments: 0), generatedAt: fixedDate)
        )
        XCTAssertLessThan(pixels(summaryOnly).height, pixels(withAll).height,
                          "没有分段时高度应当变矮，否则说明分段区是空占位")
        XCTAssertGreaterThan(pixels(summaryOnly).height, InfographicCard.width,
                             "只有摘要也不该塌成一条")
    }

    /// 标题里带 `/` `?` 这类字符时，文件名必须还能落地
    func testFileNameIsSafe() {
        XCTAssertEqual(InfographicRenderer.fileNameSafe("A/B?C"), "A-B-C")
        XCTAssertEqual(InfographicRenderer.fileNameSafe("   "), "长图")
        XCTAssertFalse(InfographicRenderer.fileNameSafe(String(repeating: "长", count: 60)).count > 24)
    }

    /// 整条链路（渲染 → 落地 PNG）能写出一个真实文件，而且是个合法 PNG
    func testWriteFileEndToEnd() throws {
        let url = try XCTUnwrap(
            InfographicRenderer.makeFile(sampleItem(), generatedAt: fixedDate),
            "长图没写出文件——分享按钮会因此不出现"
        )
        defer { try? FileManager.default.removeItem(at: url) }

        XCTAssertEqual(url.pathExtension, "png")
        let data = try Data(contentsOf: url)
        XCTAssertGreaterThan(data.count, 40_000)
        // PNG 魔数：89 50 4E 47
        XCTAssertEqual(Array(data.prefix(4)), [0x89, 0x50, 0x4E, 0x47])
    }
}
