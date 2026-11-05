import XCTest
@testable import ClipNote2

/// 标签聚合的本地规则。
///
/// 这份规则和服务端 `v2_tags_payload` 必须一致（排除回收站、同条内去重、
/// 次数倒序、同次数按名字），否则「标签页写 5 条、点进去 4 条」。
/// 两边各钉一份测试，是为了改一边时另一边会红。
@MainActor
final class TagsTests: XCTestCase {

    private func item(_ id: String, _ labels: [String]) -> Item {
        Item(id: id, title: id, metaLine: "", durationText: "", labels: labels)
    }

    func testCountsAndOrder() {
        let tags = TagsScreen.aggregate([
            item("a", ["AI", "投资"]),
            item("b", ["AI", "笔记"]),
            item("c", ["AI"]),
        ])
        XCTAssertEqual(tags.first, TagCount(name: "AI", count: 3))
        // 同次数按名字排：不排的话每次刷新顺序都在变
        XCTAssertEqual(tags.dropFirst().map(\.name), ["投资", "笔记"])
    }

    func testDuplicateLabelInOneItemCountsOnce() {
        let tags = TagsScreen.aggregate([item("a", ["AI", "AI", "AI"])])
        XCTAssertEqual(tags, [TagCount(name: "AI", count: 1)])
    }

    func testEmptyLabelsAreIgnored() {
        let tags = TagsScreen.aggregate([item("a", []), item("b", [""])])
        XCTAssertTrue(tags.isEmpty)
    }

    func testEmptyLibrary() {
        XCTAssertTrue(TagsScreen.aggregate([]).isEmpty)
    }

    // MARK: - 顶部说明

    func testSummaryCountsItemsNotTagOccurrences() {
        // 一条内容带两个标签，不能把 2 算成「2 条内容」
        let items = [
            item("a", ["AI", "科技"]),
            item("b", ["科技"]),
            item("c", []),
        ]
        let tags = TagsScreen.aggregate(items)
        let line = TagsScreen.summary(tags: tags, items: items)
        XCTAssertEqual(line, "2 个分类 · 2 条内容带标签")
    }

    // MARK: - AI 建议书签

    private func line(_ t: Int) -> APITranscriptLine { APITranscriptLine(t: t, text: "x") }

    func testSuggestParsesAndMarksAsAI() throws {
        let raw = #"{"bookmarks":[{"t":30,"note":"关键结论"}]}"#
        let list = try BookmarkSuggestor.parse(raw, transcript: [line(0), line(30)])
        XCTAssertEqual(list, [APIBookmark(t: 30, note: "关键结论", by: "ai")])
    }

    func testSuggestSnapsAndDedupes() throws {
        // 模型给了两个都落在 30 附近的值，吸附后撞车，必须去重
        let raw = #"{"bookmarks":[{"t":2,"note":"a"},{"t":3,"note":"b"}]}"#
        let list = try BookmarkSuggestor.parse(raw, transcript: [line(0), line(30)])
        XCTAssertEqual(list.count, 1)
        XCTAssertEqual(list.first?.t, 0)
    }

    func testSuggestDefaultsByToAI() throws {
        let raw = #"{"bookmarks":[{"t":0}]}"#
        let list = try BookmarkSuggestor.parse(raw, transcript: [line(0)])
        XCTAssertEqual(list.first?.by, "ai")
    }

    func testSuggestRejectsGarbage() {
        XCTAssertThrowsError(try BookmarkSuggestor.parse("模型不想干活", transcript: [line(0)]))
        XCTAssertThrowsError(try BookmarkSuggestor.parse(#"{"bookmarks":[]}"#, transcript: [line(0)]))
    }

    // MARK: - 脑图

    func testOutlineParsesNested() throws {
        let raw = #"{"outline":[{"title":"成因","note":"","children":[{"title":"资本","note":"低利率"}]}]}"#
        let nodes = try Outliner.parse(raw)
        XCTAssertEqual(nodes.count, 1)
        XCTAssertEqual(nodes[0].title, "成因")
        XCTAssertEqual(nodes[0].children.first?.title, "资本")
        XCTAssertEqual(nodes[0].children.first?.note, "低利率")
    }

    func testOutlineCapsWidth() throws {
        let items = (0..<12).map { #"{"title":"b\#($0)"}"# }.joined(separator: ",")
        let nodes = try Outliner.parse(#"{"outline":[\#(items)]}"#)
        XCTAssertLessThanOrEqual(nodes.count, 6)
    }

    func testOutlineDropsEmptyTitle() throws {
        let raw = #"{"outline":[{"title":"  "},{"title":"有效"}]}"#
        let nodes = try Outliner.parse(raw)
        XCTAssertEqual(nodes.map(\.title), ["有效"])
    }

    func testOutlineRejectsGarbage() {
        XCTAssertThrowsError(try Outliner.parse("我不想画图"))
        XCTAssertThrowsError(try Outliner.parse(#"{"outline":[]}"#))
    }

    func testOutlineMarkdown() {
        let nodes = [OutlineNode(title: "主题", children: [OutlineNode(title: "子", note: "说明")])]
        let md = nodes.map { $0.markdown() }.joined()
        XCTAssertEqual(md, "- 主题\n  - 子：说明\n")
    }

    // MARK: - 词表

    func testVocabularyIsClosedAndUnique() {
        let all = TagVocabulary.all
        XCTAssertEqual(Set(all).count, all.count, "词表里有重复项")
        XCTAssertTrue(all.contains("其他"), "没有兜底分类，模型遇到生内容只能自造")
    }

    func testPromptLineListsEveryCategory() {
        let line = TagVocabulary.promptLine
        for word in TagVocabulary.all {
            XCTAssertTrue(line.contains(word), "提示词里漏了「\(word)」")
        }
    }
}
