import XCTest
@testable import ClipNote2

/// 合集排序：按集数 / 按时间新→旧 / 按时间旧→新。
///
/// 用户原话是「按时间按钮应该可以从前往后或者从后往前，并记住当前选择」。
/// 方向这件事最容易写错的地方是「没有发布时间的集」：
/// 当成 1970 就会在正序时全部挤到最前面，看着像排序坏了。
final class SeasonOrderTests: XCTestCase {

    private func ep(_ id: String, _ created: Int) -> APISeasonEpisode {
        var one = APISeasonEpisode()
        one.videoId = id
        one.title = id
        one.created = created
        one.url = "https://www.bilibili.com/video/\(id)"
        return one
    }

    private var sample: [APISeasonEpisode] {
        // 故意把「没有时间的那一集」放中间，防止实现靠输入顺序蒙对
        [ep("a", 1_700_000_000),
         ep("noTime", 0),
         ep("c", 1_700_300_000),
         ep("b", 1_700_100_000)]
    }

    func testIndexKeepsServerOrder() {
        let out = SeasonOrder.index.sorted(sample)
        XCTAssertEqual(out.map(\.videoId), ["a", "noTime", "c", "b"])
    }

    func testNewestFirst() {
        let out = SeasonOrder.newest.sorted(sample)
        // 新 → 旧；没有时间的排最后
        XCTAssertEqual(out.map(\.videoId), ["c", "b", "a", "noTime"])
    }

    func testOldestFirst() {
        let out = SeasonOrder.oldest.sorted(sample)
        // 旧 → 新；没有时间的**仍然**排最后，不能因为正序就跑到第一
        XCTAssertEqual(out.map(\.videoId), ["a", "b", "c", "noTime"])
    }

    func testTogglingTimeFlipsDirection() {
        XCTAssertEqual(SeasonOrder.newest.toggledTime, .oldest)
        XCTAssertEqual(SeasonOrder.oldest.toggledTime, .newest)
        // 从「按集数」切到「按时间」时先看最新的（追更的人更多）
        XCTAssertEqual(SeasonOrder.index.toggledTime, .newest)
    }

    func testStoredValueFallsBackToIndex() {
        XCTAssertEqual(SeasonOrder.stored("oldest"), .oldest)
        // 旧版本存的是 "time"，不该崩、也不该猜方向
        XCTAssertEqual(SeasonOrder.stored("time"), .index)
        XCTAssertEqual(SeasonOrder.stored(""), .index)
    }

    func testLabelsCarryDirection() {
        XCTAssertEqual(SeasonOrder.index.label, "按集数")
        XCTAssertEqual(SeasonOrder.newest.label, "按时间 新→旧")
        XCTAssertEqual(SeasonOrder.oldest.label, "按时间 旧→新")
    }
}
