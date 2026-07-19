import XCTest
@testable import SnipKeyKit

/// FillInBuilder는 UI 폼이 입력한 타입 파라미터를 올바른 매크로 구문으로 조립한다.
/// 각 테스트는 (1) 정확한 문자열과 (2) MacroParser로 다시 파싱했을 때 기대한 토큰으로
/// 왕복(round-trip)되는지를 함께 검증한다. 조립이 파서와 어긋나면 사용자가 폼으로 만든
/// 매크로가 확장 때 엉뚱하게 해석되므로, 왕복이야말로 이 빌더가 지켜야 할 계약이다.
final class FillInBuilderTests: XCTestCase {

    // MARK: - fillText

    func testFillTextWithoutDefault() {
        let s = FillInBuilder.fillText(name: "URL", defaultValue: "")
        XCTAssertEqual(s, "%filltext:name=URL%")
        XCTAssertEqual(MacroParser.parse(s), [.fillText(name: "URL", defaultValue: "")])
    }

    func testFillTextWithDefault() {
        let s = FillInBuilder.fillText(name: "who", defaultValue: "world")
        XCTAssertEqual(s, "%filltext:name=who:default=world%")
        XCTAssertEqual(MacroParser.parse(s), [.fillText(name: "who", defaultValue: "world")])
    }

    // MARK: - fillArea

    func testFillAreaWithoutDefault() {
        let s = FillInBuilder.fillArea(name: "notes", defaultValue: "")
        XCTAssertEqual(s, "%fillarea:name=notes%")
        XCTAssertEqual(MacroParser.parse(s), [.fillArea(name: "notes", defaultValue: "")])
    }

    func testFillAreaWithDefault() {
        // 기본값에 든 "/"는 구분자가 아니므로 그대로 살아남아야 한다.
        let s = FillInBuilder.fillArea(name: "notes", defaultValue: "n/a")
        XCTAssertEqual(s, "%fillarea:name=notes:default=n/a%")
        XCTAssertEqual(MacroParser.parse(s), [.fillArea(name: "notes", defaultValue: "n/a")])
    }

    // MARK: - fillPopup

    func testFillPopupSeveralOptionsAndDefault() {
        let s = FillInBuilder.fillPopup(name: "plan", options: ["Basic", "Pro", "Team"], defaultValue: "Pro")
        XCTAssertEqual(s, "%fillpopup:name=plan:Basic:Pro:Team:default=Pro%")
        XCTAssertEqual(
            MacroParser.parse(s),
            [.fillPopup(name: "plan", options: ["Basic", "Pro", "Team"], defaultValue: "Pro")]
        )
    }

    func testFillPopupDropsEmptyOptionsAndOmitsEmptyDefault() {
        // 폼은 빈 옵션 행 2개로 시작한다. 사용자가 안 채운 행이 매크로에 빈 파트(::)로
        // 새어 나가면 파서가 그걸 옵션으로도, 무시로도 처리해 결과가 흔들린다 — 그래서 버린다.
        let s = FillInBuilder.fillPopup(name: "choice", options: ["A", "", "B", ""], defaultValue: "")
        XCTAssertEqual(s, "%fillpopup:name=choice:A:B%")
        XCTAssertEqual(
            MacroParser.parse(s),
            [.fillPopup(name: "choice", options: ["A", "B"], defaultValue: "")]
        )
    }

    func testFillPopupDefaultNotAmongOptionsStillEmitted() {
        // 파서는 default=를 위치와 무관하게 읽으므로, 옵션에 없는 기본값도 그대로 실어 보낸다.
        let s = FillInBuilder.fillPopup(name: "n", options: ["A", "B"], defaultValue: "Z")
        XCTAssertEqual(s, "%fillpopup:name=n:A:B:default=Z%")
        XCTAssertEqual(
            MacroParser.parse(s),
            [.fillPopup(name: "n", options: ["A", "B"], defaultValue: "Z")]
        )
    }

    // MARK: - fillPart

    func testFillPartIncludedByDefault() {
        let s = FillInBuilder.fillPart(name: "sig", includeByDefault: true, content: " best, Dan")
        XCTAssertEqual(s, "%fillpart:name=sig:default=yes% best, Dan%fillpartend%")
        let tokens = MacroParser.parse(s)
        XCTAssertEqual(tokens.first, .fillPartStart(name: "sig", defaultOn: true))
        XCTAssertEqual(tokens.last, .fillPartEnd)
        // 켜진 상태에서 렌더링하면 내용이 그대로 들어가야 한다.
        XCTAssertEqual(MacroParser.render(tokens: tokens).text, " best, Dan")
    }

    func testFillPartExcludedByDefault() {
        let s = FillInBuilder.fillPart(name: "sig", includeByDefault: false, content: "x")
        XCTAssertEqual(s, "%fillpart:name=sig:default=no%x%fillpartend%")
        XCTAssertEqual(MacroParser.parse(s).first, .fillPartStart(name: "sig", defaultOn: false))
        // 꺼진 상태로 렌더링하면 내용이 빠진다(default=no).
        XCTAssertEqual(MacroParser.render(tokens: MacroParser.parse(s)).text, "")
    }

    // MARK: - Sanitization of delimiters

    func testColonAndPercentInNameAreSanitized() {
        // 이름에 든 ':'와 '%'는 매크로 구분자라 표현 불가능하다 → 제거 후에도 이름이 깨끗하게
        // 파싱되어야 한다("a:b%c" → "abc").
        let s = FillInBuilder.fillText(name: "a:b%c", defaultValue: "")
        XCTAssertEqual(s, "%filltext:name=abc%")
        XCTAssertEqual(MacroParser.parse(s), [.fillText(name: "abc", defaultValue: "")])
    }

    func testColonInPopupOptionIsSanitized() {
        let s = FillInBuilder.fillPopup(name: "n", options: ["a:b"], defaultValue: "")
        XCTAssertEqual(s, "%fillpopup:name=n:ab%")
        XCTAssertEqual(MacroParser.parse(s), [.fillPopup(name: "n", options: ["ab"], defaultValue: "")])
    }

    func testPercentInDefaultIsSanitizedAsLastResort() {
        // '%'는 매크로 종결자라 기본값에 담을 수 없다. 폼은 검증으로 이 입력을 먼저 막지만,
        // 어떤 경로로든 '%'가 빌더에 닿으면 조용히 깨진 매크로를 만드는 대신 마지막 방어선으로
        // 제거한다. ':'와 달리 '%'는 여전히 제거된다.
        let s = FillInBuilder.fillText(name: "n", defaultValue: "50%off")
        XCTAssertEqual(s, "%filltext:name=n:default=50off%")
        XCTAssertEqual(MacroParser.parse(s), [.fillText(name: "n", defaultValue: "50off")])
    }

    // MARK: - Colon in default now survives (Part A)

    func testFillTextDefaultWithColonRoundTrips() {
        // 빌더가 만든 URL 기본값이 파서로 다시 읽었을 때 같은 토큰으로 왕복해야 한다.
        // 예전엔 ':'가 제거돼 "https//example.com"으로 망가졌다.
        let s = FillInBuilder.fillText(name: "url", defaultValue: "https://example.com")
        XCTAssertEqual(s, "%filltext:name=url:default=https://example.com%")
        XCTAssertEqual(MacroParser.parse(s), [.fillText(name: "url", defaultValue: "https://example.com")])
    }

    func testFillTextDefaultWithTimeColonRoundTrips() {
        let s = FillInBuilder.fillText(name: "t", defaultValue: "10:30")
        XCTAssertEqual(s, "%filltext:name=t:default=10:30%")
        XCTAssertEqual(MacroParser.parse(s), [.fillText(name: "t", defaultValue: "10:30")])
    }

    func testFillAreaDefaultWithColonRoundTrips() {
        let s = FillInBuilder.fillArea(name: "n", defaultValue: "a:b:c")
        XCTAssertEqual(s, "%fillarea:name=n:default=a:b:c%")
        XCTAssertEqual(MacroParser.parse(s), [.fillArea(name: "n", defaultValue: "a:b:c")])
    }

    func testFillPopupDefaultWithColonRoundTrips() {
        let s = FillInBuilder.fillPopup(name: "p", options: ["A", "B"], defaultValue: "https://a.b")
        XCTAssertEqual(s, "%fillpopup:name=p:A:B:default=https://a.b%")
        XCTAssertEqual(
            MacroParser.parse(s),
            [.fillPopup(name: "p", options: ["A", "B"], defaultValue: "https://a.b")]
        )
    }

    // MARK: - Validation helpers (Part B)

    func testValidationFlagsPercentInDefault() {
        // '%'가 든 기본값은 표현 불가 → 폼이 이걸로 Insert를 막는다.
        XCTAssertFalse(FillInBuilder.defaultValueIsRepresentable("50%off"))
        // ':'는 이제 허용된다 → 경고하지 않아야 한다.
        XCTAssertTrue(FillInBuilder.defaultValueIsRepresentable("https://example.com"))
        XCTAssertTrue(FillInBuilder.defaultValueIsRepresentable("clean value"))
    }

    func testValidationFlagsColonOrPercentInNameOrOption() {
        XCTAssertFalse(FillInBuilder.nameOrOptionIsRepresentable("a:b"))
        XCTAssertFalse(FillInBuilder.nameOrOptionIsRepresentable("a%b"))
        XCTAssertTrue(FillInBuilder.nameOrOptionIsRepresentable("clean"))
    }
}
