import XCTest
@testable import ClipNote2

/// 导出是「内容不在我手里」这个风险的唯一出口，所以把格式钉死：
/// 只要哪天改坏了分节或来源标注，用户拿到的备份就会失去可读性。
@MainActor
final class ExportTests: XCTestCase {

    private func item(
        id: String = "a",
        title: String = "一条视频",
        note: String = "",
        aiSummary: String = "",
        bookmarks: [APIBookmark] = [],
        segments: [APISegment] = [],
        outline: [OutlineNode] = []
    ) -> Item {
        Item(
            id: id,
            title: title,
            metaLine: "B 站 · 某人",
            durationText: "16:57",
            aiSummary: aiSummary,
            segments: segments,
            bookmarks: bookmarks,
            author: "某人",
            note: note,
            outline: outline,
            platform: "bilibili"
        )
    }

    func testEmptyLibraryStillHasHeader() {
        let text = LibraryExporter.markdown(items: [])
        XCTAssertTrue(text.contains("# 片记导出"))
        XCTAssertTrue(text.contains("共 0 条"))
    }

    func testSectionsAndOriginLabels() {
        let text = LibraryExporter.markdown(items: [
            item(
                aiSummary: "模型写的摘要",
                note: "我自己写的想法",
                bookmarks: [APIBookmark(t: 65, note: "关键对照", by: "user")],
                segments: [APISegment(title: "开头", t: 0, summary: "引出问题")],
                outline: [OutlineNode(title: "主线", children: [])]
            )
        ])

        XCTAssertTrue(text.contains("## 一条视频"))
        XCTAssertTrue(text.contains("### 摘要（AI）"))
        XCTAssertTrue(text.contains("### 我的笔记（我）"))
        XCTAssertTrue(text.contains("### 分段（AI）"))
        XCTAssertTrue(text.contains("### 书签（我）"))
        XCTAssertTrue(text.contains("### 脑图（AI）"))
        // 时间戳可读，不是裸秒数
        XCTAssertTrue(text.contains("01:05"))
    }

    func testAISuggestedBookmarkIsMarked() {
        let text = LibraryExporter.markdown(items: [
            item(bookmarks: [APIBookmark(t: 0, note: "模型挑的", by: "ai")])
        ])
        XCTAssertTrue(text.contains("（AI 建议）"),
                      "AI 建议的书签必须标出来，否则以后分不清哪些是自己标的")
    }

    func testOmitsEmptySections() {
        let text = LibraryExporter.markdown(items: [item()])
        XCTAssertFalse(text.contains("### 我的笔记（我）"),
                       "没有笔记就不该出现空小节")
        XCTAssertFalse(text.contains("### 脑图（AI）"))
    }

    func testTOCOnlyWhenMultipleItems() {
        let single = LibraryExporter.markdown(items: [item()])
        XCTAssertFalse(single.contains("## 目录"))

        let many = LibraryExporter.markdown(items: [item(id: "a"), item(id: "b", title: "第二条")])
        XCTAssertTrue(many.contains("## 目录"))
        XCTAssertTrue(many.contains("2. 第二条"))
    }

    func testFileIsWritten() throws {
        let url = try XCTUnwrap(LibraryExporter.write(items: [item()]))
        defer { try? FileManager.default.removeItem(at: url) }
        let text = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(text.contains("## 一条视频"))
        XCTAssertTrue(url.lastPathComponent.hasPrefix("片记导出-"))
        XCTAssertTrue(url.pathExtension == "md")
    }
}
