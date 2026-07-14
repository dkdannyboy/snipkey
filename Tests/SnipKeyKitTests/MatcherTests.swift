import XCTest
@testable import SnipKeyKit

/// `Store.Matcher.match(buffer:)`의 발화 규칙.
///
/// 약어는 두 부류이고 발화 조건이 다르다.
///   - 구두점 시작(';sig', '/addr'): 접두 구두점이 스스로 경계라 즉시 발화.
///   - 맨몸(단어 문자 시작, 'sig'): 단어 경계 + 종결자가 있어야 발화.
///
/// 두 규칙 모두 편의 기능이 아니라 정확성 요구사항이다. 규칙이 없으면 약어를
/// 품은 평범한 단어가 확장을 발화시키고, 아직 도착하지 않은 키와 백스페이스가
/// 경합해 사용자가 방금 친 글자를 비결정적으로 파괴한다.
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

    // MARK: - 오확장 방지 (약어가 단어 '안쪽'에 있는 경우)

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

    /// 단어 안쪽 약어는 '종결되어도' 발화하면 안 된다. 종결자 규칙이 앞쪽 경계
    /// 검사를 대체하는 것이 아니라, 두 조건이 모두 필요하다는 뜻이다.
    /// 'design '을 다 치고 스페이스까지 눌렀는데 서명 블록이 나오면 최악이다.
    func testWordInternalAbbreviationDoesNotMatchEvenWhenTerminated() {
        let m = makeMatcher([snippet("sig", "SIGNATURE-BLOCK")])
        XCTAssertNil(m.match(buffer: "desig "))
        XCTAssertNil(m.match(buffer: "design "))
        XCTAssertNil(m.match(buffer: "desig."))
        XCTAssertNil(m.match(buffer: "v2sig "))
        XCTAssertNil(m.match(buffer: "my_sig "))
    }

    /// 숫자와 밑줄도 단어 문자다. 'v2sig', 'my_sig' 같은 식별자 중간에서 터지면 안 된다.
    func testAbbreviationPrecededByDigitOrUnderscoreDoesNotMatch() {
        let m = makeMatcher([snippet("sig", "SIGNATURE-BLOCK")])
        XCTAssertNil(m.match(buffer: "v2sig"))
        XCTAssertNil(m.match(buffer: "my_sig"))
    }

    // MARK: - 맨몸 약어: 종결자가 있어야 확장된다

    /// 종결 없이 버퍼가 약어로 끝나는 것만으로는 발화하지 않는다.
    func testBareWordAbbreviationDoesNotMatchWithoutTerminator() {
        let m = makeMatcher([snippet("sig", "SIGNATURE-BLOCK")])
        XCTAssertNil(m.match(buffer: "sig"))
        XCTAssertNil(m.match(buffer: "hello sig"))
        XCTAssertNil(m.match(buffer: "(sig"))
    }

    /// 종결자(스페이스)가 오면 발화한다. 종결자도 함께 지워야 하므로 백스페이스는 4다.
    func testBareWordAbbreviationMatchesWithSpaceTerminator() {
        let m = makeMatcher([snippet("sig", "SIGNATURE-BLOCK")])
        let match = m.match(buffer: "sig ")
        XCTAssertEqual(match?.snippet.content, "SIGNATURE-BLOCK")
        XCTAssertEqual(match?.backspaces, 4)   // 'sig' 3 + 종결자 1
        XCTAssertEqual(match?.terminator, " ")
    }

    /// 단어 문자가 아닌 글자는 전부 종결자다.
    func testBareWordAbbreviationMatchesWithPunctuationTerminators() {
        let m = makeMatcher([snippet("sig", "SIGNATURE-BLOCK")])

        let dot = m.match(buffer: "sig.")
        XCTAssertEqual(dot?.snippet.content, "SIGNATURE-BLOCK")
        XCTAssertEqual(dot?.backspaces, 4)
        XCTAssertEqual(dot?.terminator, ".")

        for term in [",", "!", ")", "?", ";", "\n", "\t"] {
            let match = m.match(buffer: "sig\(term)")
            XCTAssertEqual(match?.snippet.content, "SIGNATURE-BLOCK", "종결자 '\(term)'")
            XCTAssertEqual(match?.backspaces, 4, "종결자 '\(term)'")
            XCTAssertEqual(match?.terminator, term, "종결자 '\(term)'")
        }
    }

    /// 버퍼 앞쪽에 다른 단어가 있어도, 약어가 단어 머리이고 종결되면 발화한다.
    func testBareWordAbbreviationMatchesAfterSpaceWhenTerminated() {
        let m = makeMatcher([snippet("sig", "SIGNATURE-BLOCK")])
        let match = m.match(buffer: "hello sig ")
        XCTAssertEqual(match?.snippet.content, "SIGNATURE-BLOCK")
        XCTAssertEqual(match?.backspaces, 4)
        XCTAssertEqual(match?.terminator, " ")
    }

    /// 앞 글자가 구두점이면 단어 경계다 — 종결자만 있으면 발화한다.
    func testBareWordAbbreviationAfterPunctuationMatchesWhenTerminated() {
        let m = makeMatcher([snippet("sig", "SIGNATURE-BLOCK")])
        XCTAssertEqual(m.match(buffer: "(sig)")?.snippet.content, "SIGNATURE-BLOCK")
        XCTAssertEqual(m.match(buffer: "(sig)")?.terminator, ")")
        XCTAssertEqual(m.match(buffer: "line\nsig ")?.snippet.content, "SIGNATURE-BLOCK")
    }

    // MARK: - 구두점 시작 약어는 즉시 발화한다 (기존 동작 보존)

    /// 구두점으로 시작하는 약어는 스스로 경계를 만든다. 접두 모호성이 없으므로
    /// 종결자를 기다리지 않고 즉시 확장된다 — 기본 스니펫(';hello', ';sig' …)이
    /// 전부 이 모양이라, 여기가 깨지면 앱이 통째로 쓸모없어진다.
    func testPunctuationPrefixedAbbreviationMatchesImmediately() {
        let m = makeMatcher([snippet(";sig", "Best regards")])
        let match = m.match(buffer: ";sig")
        XCTAssertEqual(match?.snippet.content, "Best regards")
        XCTAssertEqual(match?.backspaces, 4)   // 약어 길이 그대로
        XCTAssertEqual(match?.terminator, "")  // 다시 찍을 것이 없다
    }

    /// 접두 구두점이 경계이므로 앞 글자는 무관하다. 'a;sig'도 확장돼야 한다.
    func testPunctuationPrefixedAbbreviationMatchesEvenAfterLetter() {
        let m = makeMatcher([snippet(";sig", "Best regards")])

        let afterLetter = m.match(buffer: "a;sig")
        XCTAssertEqual(afterLetter?.snippet.content, "Best regards")
        XCTAssertEqual(afterLetter?.backspaces, 4)
        XCTAssertEqual(afterLetter?.terminator, "")

        XCTAssertEqual(m.match(buffer: "hello;sig")?.snippet.content, "Best regards")
    }

    func testSlashPrefixedAbbreviationMatchesAfterLetter() {
        let m = makeMatcher([snippet("/addr", "123 Main St")])
        let match = m.match(buffer: "x/addr")
        XCTAssertEqual(match?.snippet.content, "123 Main St")
        XCTAssertEqual(match?.backspaces, 5)
        XCTAssertEqual(match?.terminator, "")
    }

    // MARK: - 유니코드

    /// 한글도 단어 문자다. 긴 한글 단어 안에 약어가 들어 있어도 발화하면 안 된다.
    func testKoreanAbbreviationInsideLongerKoreanWordDoesNotMatch() {
        let m = makeMatcher([snippet("사인", "서명란")])
        XCTAssertNil(m.match(buffer: "회사인"))        // '회사인수' 치는 도중
        XCTAssertNil(m.match(buffer: "회사인 "))       // 종결돼도 단어 안쪽이면 안 된다
        XCTAssertEqual(m.match(buffer: "사인 ")?.snippet.content, "서명란")
        XCTAssertEqual(m.match(buffer: "여기 사인 ")?.snippet.content, "서명란")
    }

    /// 한글 약어의 백스페이스는 자소가 아니라 grapheme 기준이어야 한다.
    func testKoreanTerminatedMatchReportsGraphemeBackspaces() {
        let m = makeMatcher([snippet("사인", "서명란")])
        let match = m.match(buffer: "사인 ")
        XCTAssertEqual(match?.backspaces, 3)   // '사','인' + 공백
        XCTAssertEqual(match?.terminator, " ")
    }

    /// 악센트 라틴 문자도 단어 문자다. ASCII 검사로 때우면 여기서 깨진다.
    func testAccentedLatinCountsAsWordCharacter() {
        let m = makeMatcher([snippet("sig", "SIGNATURE-BLOCK")])
        XCTAssertNil(m.match(buffer: "ésig"))
        XCTAssertNil(m.match(buffer: "ésig "))
        // 하이픈은 단어 문자가 아니므로 경계다 — 종결되면 확장돼야 한다.
        XCTAssertEqual(m.match(buffer: "café-sig ")?.snippet.content, "SIGNATURE-BLOCK")
    }

    // MARK: - 최장 우선 스캔은 계속돼야 한다

    /// 긴 후보가 경계 검사로 거부돼도 스캔이 멈추면 안 된다. 더 짧은 접미사가
    /// 여전히 정당한 매치일 수 있다.
    func testScanContinuesAfterRejectingLongerCandidate() {
        let m = makeMatcher([
            snippet("o;hi", "WRONG"),   // 단어 문자로 시작 → 종결자 없이는 발화 못 함
            snippet(";hi", "RIGHT"),    // 구두점 시작 → 즉시 발화
        ])
        XCTAssertEqual(m.match(buffer: "no;hi")?.snippet.content, "RIGHT")
    }

    /// 맨몸 약어끼리의 최장 우선. 종결자가 붙어도 긴 쪽이 이겨야 한다.
    func testLongestBareWordAbbreviationWinsWhenTerminated() {
        let m = makeMatcher([
            snippet("sig", "SHORT"),
            snippet("sigma", "LONG"),
        ])
        let long = m.match(buffer: "sigma ")
        XCTAssertEqual(long?.snippet.content, "LONG")
        XCTAssertEqual(long?.backspaces, 6)   // 'sigma' 5 + 공백
        XCTAssertEqual(long?.terminator, " ")

        let short = m.match(buffer: "sig ")
        XCTAssertEqual(short?.snippet.content, "SHORT")
        XCTAssertEqual(short?.backspaces, 4)

        // 'sigma'를 치는 도중에는 'sig'도 발화하지 않는다.
        XCTAssertNil(m.match(buffer: "sig"))
        XCTAssertNil(m.match(buffer: "sigm"))
        XCTAssertNil(m.match(buffer: "sigma"))
    }

    /// 대소문자 무시 스니펫에도 같은 규칙이 적용된다.
    func testCaseInsensitiveSnippetAlsoRespectsWordBoundary() {
        let s = Snippet(abbreviation: "sig", content: "SIGNATURE-BLOCK", caseSensitive: false)
        let m = makeMatcher([s])
        XCTAssertNil(m.match(buffer: "deSIG"))
        XCTAssertNil(m.match(buffer: "deSIG "))
        XCTAssertNil(m.match(buffer: "SIG"))          // 종결 전
        XCTAssertEqual(m.match(buffer: "SIG ")?.snippet.content, "SIGNATURE-BLOCK")
        XCTAssertEqual(m.match(buffer: "SIG ")?.backspaces, 4)
    }
}

/// 접두 모호성(prefix ambiguity) 회귀 테스트.
///
/// 이전 경계 규칙은 약어 '앞' 글자만 봤다. 그래서 'design'(약어가 단어 안쪽)은
/// 막혔지만 'signal'(약어가 단어 '머리')은 여전히 터졌다. 사용자가 s, i, g를
/// 치는 순간 버퍼가 'sig'가 되고 앞 글자는 공백(경계)이라 엔진이 즉시 발화한다.
/// 백스페이스 3번 + 주입이 나가는 동안 n, a, l이 계속 도착해 'SIGNATURE-BLOCKnal'이
/// 된다. 사용자는 'signal'이라는 단어를 아예 칠 수 없다.
///
/// 근본 원인: 단어 문자로 시작하는 약어는 더 긴 단어의 접두사일 수 있으므로,
/// "버퍼가 약어로 끝난다"는 사실만으로는 사용자가 그 단어를 다 쳤다는 증거가
/// 되지 못한다. 종결자(terminator)가 필요하다.
final class MatcherTerminatorTests: XCTestCase {

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

    /// 단어를 한 글자씩 치는 동안 어느 시점에도 발화하면 안 된다.
    private func assertNeverMatchesWhileTyping(
        _ m: Store.Matcher,
        _ word: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        for end in 1...word.count {
            let prefix = String(word.prefix(end))
            XCTAssertNil(
                m.match(buffer: prefix),
                "'\(word)'을 치는 도중 버퍼 '\(prefix)'에서 확장이 발화했다",
                file: file,
                line: line
            )
        }
    }

    // MARK: - 약어가 더 긴 단어의 접두사일 때

    func testTypingSignalNeverMatchesSigSnippet() {
        let m = makeMatcher([snippet("sig", "SIGNATURE-BLOCK")])
        assertNeverMatchesWhileTyping(m, "signal")
    }

    func testTypingSignNeverMatchesSigSnippet() {
        let m = makeMatcher([snippet("sig", "SIGNATURE-BLOCK")])
        assertNeverMatchesWhileTyping(m, "sign")
    }

    func testTypingSignatureNeverMatchesSigSnippet() {
        let m = makeMatcher([snippet("sig", "SIGNATURE-BLOCK")])
        assertNeverMatchesWhileTyping(m, "signature")
    }

    func testTypingSigningNeverMatchesSigSnippet() {
        let m = makeMatcher([snippet("sig", "SIGNATURE-BLOCK")])
        assertNeverMatchesWhileTyping(m, "signing")
    }

    /// 한글도 같다. '사인'을 약어로 두면 '사인회'를 칠 수 없어서는 안 된다.
    func testTypingLongerKoreanWordNeverMatchesPrefixAbbreviation() {
        let m = makeMatcher([snippet("사인", "서명란")])
        assertNeverMatchesWhileTyping(m, "사인회")
        assertNeverMatchesWhileTyping(m, "사인펜")
    }

    /// 'signal '을 끝까지 치고 스페이스까지 눌러도 발화하지 않는다. 'sig'는
    /// 종결된 적이 없다 — 종결자 바로 앞 글자는 'l'이다.
    func testTerminatedLongerWordStillDoesNotMatch() {
        let m = makeMatcher([snippet("sig", "SIGNATURE-BLOCK")])
        XCTAssertNil(m.match(buffer: "signal "))
        XCTAssertNil(m.match(buffer: "signature."))
        XCTAssertNil(m.match(buffer: "사인회 "))
    }

    /// 접두 모호성이 해소되는 유일한 지점: 사용자가 종결자를 쳤을 때.
    func testUserCanStillExpandTheBareWordByTerminatingIt() {
        let m = makeMatcher([snippet("sig", "SIGNATURE-BLOCK")])
        let match = m.match(buffer: "sig ")
        XCTAssertEqual(match?.snippet.content, "SIGNATURE-BLOCK")
        XCTAssertEqual(match?.backspaces, 4)
        XCTAssertEqual(match?.terminator, " ")
    }
}
