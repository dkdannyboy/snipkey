import XCTest
@testable import SnipKeyKit

/// 날짜 계산(`%date:+1d:…%`)과 TextExpander 날짜 코드(`%Y`, `%B`, `%@+1D` …).
final class DateMacroTests: XCTestCase {

    /// 2026-03-05 14:07:09 UTC (목요일). 테스트는 Date()를 직접 쓰지 않는다.
    private let now = Date(timeIntervalSince1970: 1_772_719_629)
    private var utc: TimeZone { TimeZone(identifier: "UTC")! }
    private var en: Locale { Locale(identifier: "en_US_POSIX") }

    private func render(_ content: String) -> String {
        MacroParser.render(tokens: MacroParser.parse(content), now: now, timeZone: utc, locale: en).text
    }

    // MARK: - %date:FORMAT% (기존 동작 보존)

    func testPlainDateFormatUnchanged() {
        XCTAssertEqual(render("%date:yyyy-MM-dd%"), "2026-03-05")
        XCTAssertEqual(render("%date:HH:mm%"), "14:07")
    }

    // MARK: - 날짜 계산

    func testDateMathDays() {
        XCTAssertEqual(render("%date:+1d:yyyy-MM-dd%"), "2026-03-06")
        XCTAssertEqual(render("%date:-5d:yyyy-MM-dd%"), "2026-02-28")
    }

    func testDateMathUnits() {
        XCTAssertEqual(render("%date:+2w:yyyy-MM-dd%"), "2026-03-19")
        XCTAssertEqual(render("%date:+1M:yyyy-MM-dd%"), "2026-04-05")
        XCTAssertEqual(render("%date:-1y:yyyy%"), "2025")
        XCTAssertEqual(render("%date:+30m:HH:mm%"), "14:37")
        XCTAssertEqual(render("%date:+3h:HH%"), "17")
    }

    func testFormatThatLooksLikeMathButIsNotStaysFormat() {
        // "+1x"는 단위가 아니다 → 통째로 포맷으로 본다(기존 동작과 같다).
        XCTAssertEqual(render("%date:yyyy%"), "2026")
    }

    // MARK: - TextExpander 날짜 코드

    func testTextExpanderDateCodes() {
        XCTAssertEqual(render("%Y-%m-%d"), "2026-03-05")
        XCTAssertEqual(render("%y/%1m/%e"), "26/3/5")
        XCTAssertEqual(render("%A, %B %e"), "Thursday, March 5")
        XCTAssertEqual(render("%a %b"), "Thu Mar")
        XCTAssertEqual(render("%H:%M:%S"), "14:07:09")
        XCTAssertEqual(render("%I %p"), "02 PM")
        XCTAssertEqual(render("%1I"), "2")
    }

    func testTextExpanderDateShiftAppliesToFollowingCodes() {
        XCTAssertEqual(render("%Y-%m-%d → %@+1D%Y-%m-%d"), "2026-03-05 → 2026-03-06")
        XCTAssertEqual(render("%@-1M%B"), "February")
        XCTAssertEqual(render("%@+1Y%Y"), "2027")
    }

    // MARK: - 오인 방지

    func testPercentEncodingIsNotADateCode() {
        let url = "https://x.com/?q=%EB%AF%B8%EA%B5%AD%B0"
        XCTAssertEqual(render(url), url)
    }

    func testCodeFollowedByLetterIsLiteral() {
        XCTAssertEqual(render("50%discount 100%Money"), "50%discount 100%Money")
    }

    func testUnknownPercentStaysLiteral() {
        XCTAssertEqual(render("100% sure, 5%x"), "100% sure, 5%x")
    }

    // MARK: - 미리보기도 같은 결과

    func testPreviewMatchesRender() {
        let content = "%date:+1d:yyyy-MM-dd% %@+1D%Y"
        XCTAssertEqual(
            MacroPreview.render(content, now: now, timeZone: utc, locale: en),
            render(content)
        )
    }

    func testNestedResolutionKeepsCodes() {
        let resolved = MacroParser.resolveNested("a %snippet:x%") { _ in "%Y %@+1D%d" }
        XCTAssertEqual(render(resolved), "a 2026 06")
    }
}
