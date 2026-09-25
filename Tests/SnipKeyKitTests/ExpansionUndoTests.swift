import XCTest
@testable import SnipKeyKit

/// F3(백스페이스로 되돌리기)와 F1(앱별 제외)의 순수 로직.
final class ExpansionUndoTests: XCTestCase {

    // MARK: - 되돌리기 계획

    func testPunctuationAbbreviationUndo() throws {
        let plan = try XCTUnwrap(ExpansionUndo.plan(
            inserted: "Best regards", typed: ";sig", terminator: "",
            cursorOffsetFromEnd: 0, trailingKeys: [], fromPhysicalLayout: false
        ))
        // 사용자의 백스페이스가 이미 한 글자를 지웠다 → 나머지 11글자를 지우고 약어를 되살린다.
        XCTAssertEqual(plan.backspaces, 11)
        XCTAssertEqual(plan.restore, ";sig")
    }

    func testBareWordUndoRestoresTerminatorToo() throws {
        // 삽입된 것은 "Best regards " (종결자 포함). 사용자의 백스페이스가 종결자를 지웠다.
        let plan = try XCTUnwrap(ExpansionUndo.plan(
            inserted: "Best regards ", typed: "sig", terminator: " ",
            cursorOffsetFromEnd: 0, trailingKeys: [], fromPhysicalLayout: false
        ))
        XCTAssertEqual(plan.backspaces, 12)
        XCTAssertEqual(plan.restore, "sig ")
    }

    func testIneligibleExpansionsHaveNoPlan() {
        func plan(_ inserted: String = "x y", typed: String = ";a", cursor: Int = 0,
                  keys: [String] = [], physical: Bool = false) -> ExpansionUndo.Plan? {
            ExpansionUndo.plan(inserted: inserted, typed: typed, terminator: "",
                               cursorOffsetFromEnd: cursor, trailingKeys: keys, fromPhysicalLayout: physical)
        }
        XCTAssertNil(plan(cursor: 2), "커서가 끝이 아니면 백스페이스가 지운 자리가 끝이 아니다")
        XCTAssertNil(plan(keys: ["enter"]), "Enter가 이미 눌렸다(메시지가 보내졌을 수 있다)")
        XCTAssertNil(plan(physical: true), "한글 IME 조합은 약어 글자를 그대로 되살릴 수 없다")
        XCTAssertNil(plan(typed: ""), "팔레트 확장은 되살릴 약어가 없다")
        XCTAssertNil(plan(""), "빈 확장")
        XCTAssertNil(plan(String(repeating: "a", count: ExpansionUndo.maxUndoLength + 1)),
                     "너무 긴 확장은 백스페이스 수백 번보다 사용자의 ⌘Z가 낫다")
    }

    // MARK: - 설정 저장 형식

    func testOldSettingsDecodeWithNewDefaults() throws {
        let settings = try JSONDecoder().decode(AppSettings.self, from: Data("{}".utf8))
        XCTAssertEqual(settings.excludedBundleIDs, [])
        XCTAssertTrue(settings.undoWithBackspace)
    }

    func testExclusionIsExactBundleIDMatch() {
        var settings = AppSettings()
        settings.excludedBundleIDs = ["com.apple.Terminal"]
        XCTAssertTrue(settings.isExcluded(bundleID: "com.apple.Terminal"))
        XCTAssertFalse(settings.isExcluded(bundleID: "com.apple.TextEdit"))
        XCTAssertFalse(settings.isExcluded(bundleID: nil))
    }
}
