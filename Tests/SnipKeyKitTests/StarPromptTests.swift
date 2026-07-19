import XCTest
@testable import SnipKeyKit

/// StarPrompt.shouldPrompt은 "50배수마다, 아직 별표 안 눌렀고, 다시 묻지 않기도 안 골랐고,
/// 같은 값에서 두 번은 아닐 때만 뜬다"는 규칙 전체를 담은 순수 함수다. 각 가드가 실제로
/// 무언가를 막고 있음을 증명하도록 케이스를 짠다 — 못 하나를 빼면 정확히 어느 단언이
/// 붉어지는지 예측 가능해야 한다(CONTRIBUTING의 non-vacuity 규칙).
final class StarPromptTests: XCTestCase {

    /// 표준 상태: 아직 별표 안 눌렀고, 안 접었고, 이 값에서 띄운 적 없다.
    private func should(_ count: Int, lastPrompted: Int = 0) -> Bool {
        StarPrompt.shouldPrompt(
            expansionCount: count,
            hasStarred: false,
            dismissedForever: false,
            lastPromptedCount: lastPrompted
        )
    }

    func testPromptsAtEachMultipleOfFifty() {
        XCTAssertTrue(should(50))
        XCTAssertTrue(should(100))
        XCTAssertTrue(should(150))
    }

    func testDoesNotPromptOffMultiple() {
        XCTAssertFalse(should(49))
        XCTAssertFalse(should(51))
    }

    func testDoesNotPromptAtZero() {
        // 0도 50으로 나누어떨어지지만, 확장 한 번 없이 부탁하면 안 된다.
        XCTAssertFalse(should(0))
    }

    func testNeverPromptsOnceStarred() {
        XCTAssertFalse(StarPrompt.shouldPrompt(
            expansionCount: 50,
            hasStarred: true,
            dismissedForever: false,
            lastPromptedCount: 0
        ))
    }

    func testNeverPromptsOnceDismissedForever() {
        XCTAssertFalse(StarPrompt.shouldPrompt(
            expansionCount: 50,
            hasStarred: false,
            dismissedForever: true,
            lastPromptedCount: 0
        ))
    }

    func testDoesNotDoubleFireForSameCount() {
        // 정확히 50에서 앱을 재실행하거나 같은 값을 두 번 관측해도, 이미 50에서 띄웠으면
        // 다시 뜨면 안 된다.
        XCTAssertFalse(should(50, lastPrompted: 50))
    }

    func testPromptsAgainAtNextMultipleAfterEarlierPrompt() {
        // 50에서 띄운 뒤(lastPrompted=50) 100에 도달하면 다시 떠야 한다.
        XCTAssertTrue(should(100, lastPrompted: 50))
    }
}
