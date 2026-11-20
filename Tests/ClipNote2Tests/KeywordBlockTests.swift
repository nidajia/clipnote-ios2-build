import XCTest
@testable import ClipNote2

/// 关键词屏蔽的验收点：命中就整条消失、撤销能回来、重复加不会出现两条。
final class KeywordBlockTests: XCTestCase {

    func testMatchesTitleRegardlessOfWidthOrCase() {
        XCTAssertTrue(KeywordBlock.matches("Ai 泡沫复盘：这一轮不一样", keywords: ["复盘"]))
        XCTAssertTrue(KeywordBlock.matches("ＡＩ泡沫复盘", keywords: ["ai泡沫"]))
        XCTAssertTrue(KeywordBlock.matches("AI 泡沫", keywords: ["ai"]))
        XCTAssertFalse(KeywordBlock.matches("一次讲清楚复利", keywords: ["复盘"]))
        XCTAssertFalse(KeywordBlock.matches("任何标题", keywords: ["  "]), "空关键词不该命中一切")
    }

    func testFilterKeepsEverythingWhenNoKeyword() {
        let titles = ["复盘一", "正常的视频"]
        let kept = KeywordBlock.filter(titles, keywords: [], title: { $0 })
        XCTAssertEqual(kept, titles)
    }

    func testAddingIgnoresDuplicatesAndBlank() {
        var list = KeywordBlock.adding("复盘", to: [])
        list = KeywordBlock.adding(" 复盘 ", to: list)
        list = KeywordBlock.adding("", to: list)
        XCTAssertEqual(list, ["复盘"])
    }

    func testRemovingRestoresTheList() {
        let list = ["复盘", "带货"]
        XCTAssertEqual(KeywordBlock.removing("复盘", from: list), ["带货"])
        XCTAssertEqual(KeywordBlock.removing("不存在", from: list), list)
    }

    func testSuggestionsCutTheTitleIntoUsableWords() {
        let words = KeywordBlock.suggestions(from: "AI泡沫为何比2000年更危险？复盘与推演")
        XCTAssertTrue(words.contains("复盘与推演"), "按标点切开后应能直接选")
        XCTAssertFalse(words.contains("AI泡沫为何比2000年更危险"), "超过 12 字的整句不作候选")
    }

    func testEncodeDecodeRoundTrip() {
        let list = ["复盘", "荐股"]
        XCTAssertEqual(KeywordBlock.decode(KeywordBlock.encode(list)), list)
        XCTAssertEqual(KeywordBlock.decode("not json"), [])
    }
}
