import XCTest
@testable import SnipKeyKit

/// 대소문자 따라가기(F2): 입력한 약어의 대소문자를 확장 결과에 옮긴다.
final class CaseAdapterTests: XCTestCase {

    // MARK: - 변환 규칙

    func testTypedAsStoredLeavesTextAlone() {
        XCTAssertEqual(CaseAdapter.adapt("best regards", typed: ";sig", abbreviation: ";sig"), "best regards")
    }

    func testCapitalizedAbbreviationCapitalizesFirstLetter() {
        XCTAssertEqual(CaseAdapter.adapt("best regards", typed: ";Sig", abbreviation: ";sig"), "Best regards")
    }

    func testAllCapsAbbreviationUppercasesEverything() {
        XCTAssertEqual(CaseAdapter.adapt("best regards", typed: ";SIG", abbreviation: ";sig"), "BEST REGARDS")
    }

    func testFirstLetterFoundPastLeadingPunctuation() {
        XCTAssertEqual(CaseAdapter.adapt("— thanks", typed: "Ty", abbreviation: "ty"), "— Thanks")
    }

    func testLowercaseTypingOfCapitalizedAbbreviationChangesNothing() {
        XCTAssertEqual(CaseAdapter.adapt("Seoul", typed: ";addr", abbreviation: ";Addr"), "Seoul")
    }

    func testUncasedScriptsAreANoOp() {
        // 한글에는 대소문자가 없다 — 아무것도 바꾸지 않는다.
        XCTAssertEqual(CaseAdapter.adapt("감사합니다", typed: ";ㄱㅅ", abbreviation: ";ㄱㅅ"), "감사합니다")
        XCTAssertEqual(CaseAdapter.adapt("hello", typed: ";1", abbreviation: ";1"), "hello")
    }

    // MARK: - 매처가 입력한 약어를 넘겨준다

    func testMatcherReportsTypedAbbreviation() {
        let s = Snippet(abbreviation: ";sig", content: "x", caseSensitive: true, adaptCase: true)
        let matcher = Store.Matcher(maxLength: 4, exact: [:], insensitive: [";sig": s])
        XCTAssertEqual(matcher.match(buffer: "hi ;SIG")?.typed, ";SIG")
        XCTAssertEqual(matcher.match(buffer: "Sig.")?.typed, nil)
    }

    func testBareWordMatchReportsTypedWithoutTerminator() {
        let s = Snippet(abbreviation: "sig", content: "x", caseSensitive: false, adaptCase: true)
        let matcher = Store.Matcher(maxLength: 3, exact: [:], insensitive: ["sig": s])
        XCTAssertEqual(matcher.match(buffer: "Sig ")?.typed, "Sig")
    }

    // MARK: - 저장 형식

    func testAdaptCaseImpliesCaseInsensitiveMatching() {
        let s = Snippet(abbreviation: ";sig", content: "x", caseSensitive: true, adaptCase: true)
        XCTAssertTrue(s.matchesCaseInsensitively)
    }

    func testOldSnippetJSONWithoutAdaptCaseDecodes() throws {
        let json = """
        {"abbreviation":";a","caseSensitive":true,"content":"x","createdAt":"2025-01-02T03:04:05Z",
         "enabled":true,"id":"E621E1F8-C36C-495A-93FC-0C247A3E6E5F","label":"","modifiedAt":"2025-01-02T03:04:05Z"}
        """
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        let s = try d.decode(Snippet.self, from: Data(json.utf8))
        XCTAssertFalse(s.adaptCase)
    }

    func testAdaptCaseIsOmittedFromJSONWhenOff() throws {
        // 쓰지 않는 사용자의 파일은 바이트 하나 바뀌지 않아야 한다(동기화 잡음 방지).
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        let off = String(data: try e.encode(Snippet(abbreviation: "a", content: "b")), encoding: .utf8)!
        XCTAssertFalse(off.contains("adaptCase"))
        let on = String(data: try e.encode(Snippet(abbreviation: "a", content: "b", adaptCase: true)), encoding: .utf8)!
        XCTAssertTrue(on.contains("\"adaptCase\":true"))
    }
}
