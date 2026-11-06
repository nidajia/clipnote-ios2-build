import XCTest
@testable import ClipNote2

/// 搜索的验收点只有一条：**输入框说能搜的东西，必须真的能搜到**。
/// 之前占位文案写着「标题、要点、标签」，实现只匹配标题——这类不一致
/// 用户会当成「搜索坏了」，而不是「文案写错了」。
@MainActor
final class SearchTests: XCTestCase {

    private func item(
        title: String = "无关标题",
        author: String = "",
        labels: [String] = [],
        keyPoints: [String] = [],
        note: String = "",
        aiSummary: String = "",
        bookmarks: [APIBookmark] = []
    ) -> Item {
        Item(
            id: "x",
            title: title,
            metaLine: "B 站 · 某人",
            durationText: "10:00",
            aiSummary: aiSummary,
            keyPoints: keyPoints,
            labels: labels,
            bookmarks: bookmarks,
            author: author,
            note: note
        )
    }

    func testMatchesTitle() {
        XCTAssertTrue(LibrarySearch.matches(item(title: "固态硬盘渠道价"), query: "硬盘"))
    }

    func testMatchesAuthor() {
        XCTAssertTrue(LibrarySearch.matches(item(author: "玄离199"), query: "玄离"))
    }

    func testMatchesLabel() {
        // 输入框承诺可搜标签，这条保证承诺成立
        XCTAssertTrue(LibrarySearch.matches(item(labels: ["AI", "投资"]), query: "投资"))
    }

    func testMatchesKeyPoints() {
        XCTAssertTrue(LibrarySearch.matches(
            item(keyPoints: ["估值跑在收入前面"]), query: "估值"))
    }

    func testMatchesNote() {
        XCTAssertTrue(LibrarySearch.matches(
            item(note: "这套对照实验能套到容量评估"), query: "容量"))
    }

    func testMatchesBookmarkNote() {
        XCTAssertTrue(LibrarySearch.matches(
            item(bookmarks: [APIBookmark(t: 10, note: "折旧周期错配")]), query: "折旧"))
    }

    func testMultipleTermsMustAllMatch() {
        let one = item(title: "AI 泡沫何时破裂", note: "讲的是估值与收入缺口")
        XCTAssertTrue(LibrarySearch.matches(one, query: "泡沫 估值"))
        XCTAssertFalse(LibrarySearch.matches(one, query: "泡沫 光伏"))
    }

    func testTermsMatchAcrossDifferentFields() {
        // 「标题里有 A、笔记里有 B」也算命中：人记关键词时不会区分它在哪个字段
        let one = item(title: "AI 泡沫", note: "提到 NVDA 的资本开支")
        XCTAssertTrue(LibrarySearch.matches(one, query: "泡沫 NVDA"))
    }

    func testCaseInsensitive() {
        XCTAssertTrue(LibrarySearch.matches(item(title: "Vibe Coding 实践"), query: "vibe"))
    }

    func testEmptyQueryMatchesEverything() {
        XCTAssertTrue(LibrarySearch.matches(item(), query: "   "))
    }

    func testNoMatchReturnsFalse() {
        XCTAssertFalse(LibrarySearch.matches(item(title: "固态硬盘"), query: "光伏"))
    }
}
