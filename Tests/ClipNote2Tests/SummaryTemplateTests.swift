import XCTest
@testable import ClipNote2

/// 模板的验收点：**换完之后模型收到的指令真的不同**。
/// 如果只是界面上换了名字、提示词没变，用户会看到两份一模一样的摘要，
/// 然后认为这个功能是假的。
@MainActor
final class SummaryTemplateTests: XCTestCase {

    private func prompt(_ template: SummaryTemplate, custom: String = "") -> String {
        Summarizer.instructions(template: template, customPrompt: custom)
    }

    func testBriefKeepsBasePromptOnly() {
        let base = prompt(.brief)
        XCTAssertTrue(base.contains("内容摘要助手"))
        XCTAssertFalse(base.contains("论点拆解"))
        XCTAssertFalse(base.contains("行动清单"))
    }

    func testEachTemplateAddsItsOwnInstruction() {
        XCTAssertTrue(prompt(.argument).contains("论点拆解"))
        XCTAssertTrue(prompt(.timeline).contains("时间线"))
        XCTAssertTrue(prompt(.action).contains("行动清单"))
        XCTAssertTrue(prompt(.question).contains("追问式"))
    }

    func testInstructionsAreDistinct() {
        let all = SummaryTemplate.allCases
            .filter { $0 != .custom }
            .map { prompt($0) }
        XCTAssertEqual(Set(all).count, all.count,
                       "两个模板产出的提示词必须不同，否则换了等于没换")
    }

    func testCustomUsesUserText() {
        let text = prompt(.custom, custom: "只列反面证据")
        XCTAssertTrue(text.contains("只列反面证据"))
    }

    func testCustomBlankAddsNothing() {
        // 自定义留空时不该往提示词里塞空白，否则等于给模型一句无意义的话
        XCTAssertEqual(prompt(.custom, custom: "   "), prompt(.brief))
    }

    func testBaseStillForbidsFabrication() {
        // 任何模板都不能把「不要编造」这条约束冲掉
        for template in SummaryTemplate.allCases {
            XCTAssertTrue(prompt(template, custom: "随便写").contains("不要编造"),
                          "\(template.title) 模板破坏了「不许编造」这条底线")
        }
    }
}
