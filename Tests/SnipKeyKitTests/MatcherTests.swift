import XCTest
@testable import SnipKeyKit

/// `Store.Matcher.match(buffer:)`의 단어 경계 규칙.
///
/// 경계 검사가 없으면 약어를 부분 문자열로 품은 평범한 단어가 확장을 발화시킨다.
/// 'sig' 스니펫을 둔 채 'design'을 치면 'desig' 시점에 엔진이 터져서, 사용자가
/// 방금 친 글자를 백스페이스가 갉아먹는 데이터 손상이 된다. 그래서 이건
/// 편의 기능이 아니라 정확성 요구사항이다.
final class MatcherWordBoundaryTests: XCTestCase {

    /// 스니펫 목록으로 매처를 만든다. Store의 rebuildIndex와 같은 규칙.
    private func makeMatcher(_ snippets: [Snippet]) -> Store.Matcher {
        var exact: [String: Snippet] = [:]
        var insensitive: [String: Snippet] = [:]
        var maxLen = 0
        for s in snippets {
            maxLen = max(maxLen, s.abbreviation.count)
            if s.caseSensitive {
                exact[s.abbreviation] = s
            } else {
                insensitive[s.abbreviation.lowercased()] = s
            }
        }
        return Store.Matcher(maxLength: maxLen, exact: exact, insensitive: insensitive)
    }

    private func snippet(_ abbr: String, _ content: String) -> Snippet {
        Snippet(abbreviation: abbr, content: content, caseSensitive: true)
    }

    // MARK: - 오확장 방지

    /// 핵심 회귀 테스트. 'design'을 치는 도중 어느 시점에도 'sig'가 발화하면 안 된다.
    func testTypingDesignNeverMatchesSigSnippet() {
        let m = makeMatcher([snippet("sig", "SIGNATURE-BLOCK")])
        let word = "design"
        for end in 1...word.count {
            let prefix = String(word.prefix(end))
            XCTAssertNil(
                m.match(buffer: prefix),
                "'design'을 치는 도중 버퍼 '\(prefix)'에서 확장이 발화했다"
            )
        }
    }

    /// 앞 글자가 단어 문자면 거부한다는 규칙 그 자체.
    func testAbbreviationPrecededByLetterDoesNotMatch() {
        let m = makeMatcher([snippet("sig", "SIGNATURE-BLOCK")])
        XCTAssertNil(m.match(buffer: "desig"))
        XCTAssertNil(m.match(buffer: "Xsig"))
    }

    /// 숫자와 밑줄도 단어 문자다. 'v2sig', 'my_sig' 같은 식별자 중간에서 터지면 안 된다.
    func testAbbreviationPrecededByDigitOrUnderscoreDoesNotMatch() {
        let m = makeMatcher([snippet("sig", "SIGNATURE-BLOCK")])
        XCTAssertNil(m.match(buffer: "v2sig"))
        XCTAssertNil(m.match(buffer: "my_sig"))
    }

    // MARK: - 정상 확장은 그대로 살아 있어야 한다

    func testAbbreviationAtBufferStartMatches() {
        let m = makeMatcher([snippet("sig", "SIGNATURE-BLOCK")])
        XCTAssertEqual(m.match(buffer: "sig")?.content, "SIGNATURE-BLOCK")
    }

    func testAbbreviationAfterSpaceMatches() {
        let m = makeMatcher([snippet("sig", "SIGNATURE-BLOCK")])
        XCTAssertEqual(m.match(buffer: "hello sig")?.content, "SIGNATURE-BLOCK")
    }

    /// 앞 글자가 구두점이면 단어 경계다.
    func testAbbreviationAfterPunctuationMatches() {
        let m = makeMatcher([snippet("sig", "SIGNATURE-BLOCK")])
        XCTAssertEqual(m.match(buffer: "(sig")?.content, "SIGNATURE-BLOCK")
        XCTAssertEqual(m.match(buffer: "line\nsig")?.content, "SIGNATURE-BLOCK")
    }

    /// 구두점으로 시작하는 약어는 스스로 경계를 만든다. 글자 바로 뒤에 와도
    /// 지금처럼 확장돼야 한다 — 기본 스니펫(';hello', ';sig' …)이 전부 이 모양이다.
    func testPunctuationPrefixedAbbreviationMatchesEvenAfterLetter() {
        let m = makeMatcher([snippet(";sig", "Best regards")])
        XCTAssertEqual(m.match(buffer: ";sig")?.content, "Best regards")
        XCTAssertEqual(m.match(buffer: "a;sig")?.content, "Best regards")
        XCTAssertEqual(m.match(buffer: "hello;sig")?.content, "Best regards")
    }

    func testSlashPrefixedAbbreviationMatchesAfterLetter() {
        let m = makeMatcher([snippet("/addr", "123 Main St")])
        XCTAssertEqual(m.match(buffer: "x/addr")?.content, "123 Main St")
    }

    // MARK: - 유니코드

    /// 한글도 단어 문자다. 긴 한글 단어 안에 약어가 들어 있어도 발화하면 안 된다.
    func testKoreanAbbreviationInsideLongerKoreanWordDoesNotMatch() {
        let m = makeMatcher([snippet("사인", "서명란")])
        XCTAssertNil(m.match(buffer: "회사인"))       // '회사인수' 치는 도중
        XCTAssertEqual(m.match(buffer: "사인")?.content, "서명란")
        XCTAssertEqual(m.match(buffer: "여기 사인")?.content, "서명란")
    }

    /// 악센트 라틴 문자도 단어 문자다. ASCII 검사로 때우면 여기서 깨진다.
    func testAccentedLatinCountsAsWordCharacter() {
        let m = makeMatcher([snippet("sig", "SIGNATURE-BLOCK")])
        XCTAssertNil(m.match(buffer: "ésig"))
        // 하이픈은 단어 문자가 아니므로 경계다 — 확장돼야 한다.
        XCTAssertEqual(m.match(buffer: "café-sig")?.content, "SIGNATURE-BLOCK")
    }

    // MARK: - 최장 우선 스캔은 계속돼야 한다

    /// 긴 후보가 경계 검사로 거부돼도 스캔이 멈추면 안 된다. 더 짧은 접미사가
    /// 여전히 정당한 매치일 수 있다.
    func testScanContinuesAfterRejectingLongerCandidate() {
        let m = makeMatcher([
            snippet("o;hi", "WRONG"),   // 단어 문자로 시작 → 'n' 뒤에서는 거부돼야 함
            snippet(";hi", "RIGHT"),    // 구두점 시작 → 살아남아야 함
        ])
        XCTAssertEqual(m.match(buffer: "no;hi")?.content, "RIGHT")
    }

    /// 대소문자 무시 스니펫에도 같은 규칙이 적용된다.
    func testCaseInsensitiveSnippetAlsoRespectsWordBoundary() {
        let s = Snippet(abbreviation: "sig", content: "SIGNATURE-BLOCK", caseSensitive: false)
        let m = makeMatcher([s])
        XCTAssertNil(m.match(buffer: "deSIG"))
        XCTAssertEqual(m.match(buffer: "SIG")?.content, "SIGNATURE-BLOCK")
    }
}
