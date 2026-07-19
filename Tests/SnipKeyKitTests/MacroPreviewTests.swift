import XCTest
@testable import SnipKeyKit

/// `MacroPreview.render`의 명세 테스트. 미리보기는 부작용 없이 확장 결과의 *모양*을
/// 보여줘야 하므로, 토큰 종류별로 정확히 무엇이 보이고 무엇이 보이지 않아야 하는지를 고정한다.
final class MacroPreviewTests: XCTestCase {

    // MARK: - 결정론적 날짜 주입용 기준 시각
    //
    // Calendar.current로 만들고 DateFormatter도 같은 시스템 타임존으로 렌더링하므로,
    // 어떤 머신/타임존에서도 "2026-07-20"이 일관되게 나온다(빌드와 포맷이 같은 달력을 쓴다).
    private var fixedNow: Date {
        var comps = DateComponents()
        comps.year = 2026
        comps.month = 7
        comps.day = 20
        comps.hour = 12
        return Calendar.current.date(from: comps)!
    }

    func testPlainText() {
        XCTAssertEqual(MacroPreview.render("hello world", now: fixedNow), "hello world")
    }

    func testFillTextWithoutDefaultShowsFieldNameInParens() {
        XCTAssertEqual(MacroPreview.render("%filltext:name=URL%", now: fixedNow), "(URL)")
    }

    func testFillTextWithDefaultShowsDefault() {
        XCTAssertEqual(MacroPreview.render("%filltext:name=who:default=world%", now: fixedNow), "world")
    }

    func testFillAreaWithoutDefaultShowsFieldNameInParens() {
        XCTAssertEqual(MacroPreview.render("%fillarea:name=notes%", now: fixedNow), "(notes)")
    }

    func testFillPopupPrefersDefault() {
        let content = "%fillpopup:name=choice:option A:option B:default=option B%"
        XCTAssertEqual(MacroPreview.render(content, now: fixedNow), "option B")
    }

    func testFillPopupFallsBackToFirstOptionWhenNoDefault() {
        let content = "%fillpopup:name=choice:option A:option B%"
        XCTAssertEqual(MacroPreview.render(content, now: fixedNow), "option A")
    }

    func testFillPopupFallsBackToNameWhenNoDefaultOrOptions() {
        XCTAssertEqual(MacroPreview.render("%fillpopup:name=choice%", now: fixedNow), "(choice)")
    }

    func testFillPartIncludedWhenDefaultOn() {
        let content = "A%fillpart:name=p:default=yes% optional%fillpartend% B"
        XCTAssertEqual(MacroPreview.render(content, now: fixedNow), "A optional B")
    }

    func testFillPartOmittedWhenDefaultOff() {
        // 비-공허 검증의 핵심 케이스: default=no면 감싼 섹션 전체가 사라져야 한다.
        let content = "A%fillpart:name=p:default=no% secret%fillpartend% B"
        XCTAssertEqual(MacroPreview.render(content, now: fixedNow), "A B")
    }

    func testNestedFillPartOuterOffSwallowsInner() {
        // 바깥이 꺼지면 안쪽이 켜져 있어도 통째로 사라진다(짝짓기 중첩 처리).
        let content = "X%fillpart:name=o:default=no%a%fillpart:name=i:default=yes%b%fillpartend%c%fillpartend%Y"
        XCTAssertEqual(MacroPreview.render(content, now: fixedNow), "XY")
    }

    func testMissingEndOnOffPartTreatsRemainingAsIncluded() {
        // 종료 마커가 없으면 남은 내용을 감추지 않고 포함한다(사용자 텍스트 보호).
        let content = "keep%fillpart:name=p:default=no% and this too"
        XCTAssertEqual(MacroPreview.render(content, now: fixedNow), "keep and this too")
    }

    func testClipboardPlaceholder() {
        XCTAssertEqual(MacroPreview.render("%clipboard", now: fixedNow), "[clipboard]")
    }

    func testSnippetPlaceholderShowsAbbreviationInBrackets() {
        XCTAssertEqual(MacroPreview.render("%snippet:;sig%", now: fixedNow), "[;sig]")
    }

    func testKeyAndCursorAreInvisible() {
        let content = "a%key:enter%b%|c"
        XCTAssertEqual(MacroPreview.render(content, now: fixedNow), "abc")
    }

    func testDateWithFixedNow() {
        XCTAssertEqual(MacroPreview.render("%date:yyyy-MM-dd%", now: fixedNow), "2026-07-20")
    }

    func testRealisticMixedContent() {
        let content = "Hi %filltext:name=name:default=there%, see %snippet:;addr% — %clipboard%|"
        XCTAssertEqual(
            MacroPreview.render(content, now: fixedNow),
            "Hi there, see [;addr] — [clipboard]"
        )
    }
}
