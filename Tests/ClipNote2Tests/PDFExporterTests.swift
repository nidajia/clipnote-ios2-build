import XCTest
@testable import ClipNote2

/// PDF 的验收点：**能被任何阅读器打开，且内容真的排进去了**。
/// 排版细节无法自动断言，但「文件是不是 PDF」「分页有没有内容」这两条能挡住最糟的失败：
/// 一个 0 页的 PDF，或者只画了标题的 PDF。
@MainActor
final class PDFExporterTests: XCTestCase {

    private func item(segments: Int = 3, note: String = "") -> Item {
        Item(
            id: "p1",
            title: "一条用于导出测试的视频",
            metaLine: "B 站 · 某人",
            durationText: "16:57",
            aiSummary: "这段摘要用来验证正文段落能不能排进 PDF，长度大约两行。",
            keyPoints: ["第一条要点", "第二条要点"],
            labels: ["AI", "投资"],
            segments: (0..<segments).map {
                APISegment(title: "第\($0 + 1)段", t: $0 * 60, summary: "这一段讲了点东西")
            },
            author: "某人",
            note: note,
            platform: "bilibili"
        )
    }

    func testProducesValidPDF() throws {
        let data = try XCTUnwrap(PDFExporter.makeData(item()))
        XCTAssertGreaterThan(data.count, 800,
                             "PDF 太小，多半只画了空页")
        let head = String(data: data.prefix(5), encoding: .ascii)
        XCTAssertEqual(head, "%PDF-", "文件头不对，阅读器会直接拒绝打开")
    }

    func testPagesGrowWithContent() throws {
        let short = try XCTUnwrap(PDFExporter.makeData(item(segments: 2)))
        let long = try XCTUnwrap(PDFExporter.makeData(item(segments: 40, note: String(repeating: "笔记内容。", count: 200))))
        XCTAssertGreaterThan(long.count, short.count,
                             "内容变多文件却没变大，说明分页没生效或内容被截断")
    }

    func testAttributedTextHasAllSections() {
        let text = PDFExporter.attributedText(for: item(note: "我自己写的想法"))
            .string
        XCTAssertTrue(text.contains("一条用于导出测试的视频"))
        XCTAssertTrue(text.contains("摘要"))
        XCTAssertTrue(text.contains("我的笔记"))
        XCTAssertTrue(text.contains("分段"))
        XCTAssertTrue(text.contains("第一条要点"))
    }

    func testEmptyOptionalSectionsAreOmitted() {
        let plain = Item(id: "x", title: "只有标题",
                         metaLine: "", durationText: "")
        let text = PDFExporter.attributedText(for: plain).string
        XCTAssertFalse(text.contains("我的笔记"), "没有笔记不该出现空小节")
        XCTAssertFalse(text.contains("批注"))
        XCTAssertFalse(text.contains("脑图"))
    }

    func testFileNameSanitized() {
        let weird = Item(id: "x", title: "a/b:c", metaLine: "", durationText: "")
        let name = PDFExporter.fileName(for: weird)
        XCTAssertFalse(name.contains("/"), "文件名里的斜杠会变成目录分隔符")
        XCTAssertFalse(name.contains(":"))
        XCTAssertTrue(name.hasSuffix(".pdf"))
    }

    func testWriteLandsOnDisk() throws {
        let url = try XCTUnwrap(PDFExporter.write(item()))
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
        XCTAssertGreaterThan(size ?? 0, 800)
    }
}
