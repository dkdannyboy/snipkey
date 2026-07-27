import XCTest
@testable import SnipKeyKit

/// 이중 버퍼(표시/물리) 매칭 결정 로직.
///
/// TextExpander식 레이아웃 기반 매칭: 한글 IME에서 물리 QWERTY 키가 영문 약어를
/// 이루면 물리 버퍼로 발화하고, 삭제 수는 화면에 보이는 조합 글자 수로 계산한다.
/// 영문/ABC 모드에서는 표시 버퍼가 우선해 정확히 한 번만 발화한다(이중 확장 없음).
///
/// 결정 로직을 CGEvent 콜백에서 꺼내 순수 함수로 검증한다 — 실제 이벤트 탭 없이.
final class LayoutAwareMatcherTests: XCTestCase {

    /// Store.rebuildIndex와 같은 규칙으로 매처를 만든다.
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

    private func snippet(_ abbr: String, _ content: String, caseSensitive: Bool = false) -> Snippet {
        Snippet(abbreviation: abbr, content: content, caseSensitive: caseSensitive)
    }

    // 한글 2벌식 조합용(conjoining) jamo. NFC 정규화 시 완성형 음절로 합쳐진다.
    //   c→ᄎ(U+110E 초성) l→ᅵ(U+1175 중성) e→ᆮ(U+11AE 종성) → "칟"
    //   a→ᄆ(U+1106 초성) r→ᅡ(U+1161 중성)                 → "마"
    private let jamoC = "\u{110E}"
    private let jamoL = "\u{1175}"
    private let jamoE = "\u{11AE}"
    private let jamoA = "\u{1106}"
    private let jamoR = "\u{1161}"

    // MARK: - ABC 모드: 표시 버퍼 우선, 단 한 번만 발화

    /// 영문/ABC 모드에서는 표시 버퍼와 물리 버퍼가 동일하다. 결정은 반드시 표시
    /// 버퍼(.composed)에서 나오고, 물리 버퍼로 다시 발화하지 않는다(이중 확장 없음).
    func testAbcModeFiresFromComposedBufferExactlyOnce() {
        let m = makeMatcher([snippet(";clear", "CLEARED")])
        var layout = LayoutBuffer()
        let keys: [(String, Character)] =
            [(";", ";"), ("c", "c"), ("l", "l"), ("e", "e"), ("a", "a"), ("r", "r")]
        for (composed, physical) in keys {
            layout.appendLiteral(composed: composed, physical: physical)
        }
        // 엔진의 표시 버퍼 = 물리 버퍼 = ";clear"
        let composedBuffer = ";clear"

        // 두 버퍼 모두 매치되지만, 결정은 표시 버퍼 하나만 반환한다.
        XCTAssertNotNil(m.match(buffer: composedBuffer))
        XCTAssertNotNil(m.match(buffer: layout.physical))

        let decision = LayoutAwareMatcher.decide(
            composedBuffer: composedBuffer, layout: layout, matcher: m,
            allowPhysicalFallback: true
        )
        XCTAssertEqual(decision?.source, .composed)
        XCTAssertEqual(decision?.match.snippet.abbreviation, ";clear")
        // ABC 모드에서는 물리 키 수 == 화면 글자 수 == 6.
        XCTAssertEqual(decision?.backspaces, 6)
        XCTAssertEqual(decision?.terminator, "")
    }

    // MARK: - 한글 IME 모드: 물리 버퍼로 발화

    /// 화면에는 조합용 jamo가 찍혀(표시 버퍼는 어떤 약어와도 불일치) 있지만,
    /// 물리 키는 ";clear"를 이룬다. 결정은 물리 버퍼(.physical)에서 나온다.
    func testKoreanImeFiresFromPhysicalBuffer() {
        let m = makeMatcher([snippet(";clear", "CLEARED")])
        var layout = LayoutBuffer()
        let composedJamo = [";", jamoC, jamoL, jamoE, jamoA, jamoR]
        let physicalKeys: [Character] = [";", "c", "l", "e", "a", "r"]
        for i in physicalKeys.indices {
            layout.appendLiteral(composed: composedJamo[i], physical: physicalKeys[i])
        }
        // 표시 버퍼(엔진 buffer)는 조합용 jamo의 연결 — 약어와 일치하지 않는다.
        let composedBuffer = composedJamo.joined()
        XCTAssertNil(
            m.match(buffer: composedBuffer),
            "표시 버퍼가 약어와 일치하면 이 테스트는 물리 경로를 검증하지 못한다"
        )

        // 게이트가 열려 있어야(두벌식) 물리 폴백이 동작한다.
        let decision = LayoutAwareMatcher.decide(
            composedBuffer: composedBuffer, layout: layout, matcher: m,
            allowPhysicalFallback: true
        )
        XCTAssertEqual(decision?.source, .physical)
        XCTAssertEqual(decision?.match.snippet.abbreviation, ";clear")
        // 물리 키는 6개지만 화면 조합 글자는 ";칟ㅁㄱ" 4개. 삭제는 반드시 4여야 한다.
        // (두벌식 r→ㄱ이므로 ㅁ·ㄱ은 각각 낱자로 남는다 — 물리 키 오토마톤 결과.)
        XCTAssertEqual(decision?.backspaces, 4)
        XCTAssertEqual(decision?.terminator, "")  // 구두점 시작 약어는 종결자 없음
    }

    // MARK: - 물리 폴백 게이트: 두벌식이 아니면 물리 매치를 억제

    /// 물리 키는 ";clear"를 이루지만(표시 버퍼는 어떤 약어와도 불일치),
    /// 게이트가 닫혀 있으면(두벌식 아님: 세벌식·일본어·중국어·미지 IME) 물리 폴백을
    /// 건너뛰어 결정은 nil이어야 한다 — 기능 도입 이전과 동일하게 발화하지 않는다.
    /// 이 테스트가 게이트의 핵심 안전장치를 증명한다.
    func testPhysicalOnlyMatchSuppressedWhenGateFalse() {
        let m = makeMatcher([snippet(";clear", "CLEARED")])
        var layout = LayoutBuffer()
        let composedJamo = [";", jamoC, jamoL, jamoE, jamoA, jamoR]
        let physicalKeys: [Character] = [";", "c", "l", "e", "a", "r"]
        for i in physicalKeys.indices {
            layout.appendLiteral(composed: composedJamo[i], physical: physicalKeys[i])
        }
        let composedBuffer = composedJamo.joined()
        // 사전조건: 물리 버퍼는 실제로 매치된다(게이트만 억제 요인임을 못박는다).
        XCTAssertNotNil(m.match(buffer: layout.physical))
        XCTAssertNil(m.match(buffer: composedBuffer))

        let decision = LayoutAwareMatcher.decide(
            composedBuffer: composedBuffer, layout: layout, matcher: m,
            allowPhysicalFallback: false
        )
        XCTAssertNil(decision, "게이트가 닫히면 물리 전용 매치는 발화하지 않아야 한다")
    }

    /// 게이트가 닫혀 있어도 표시 버퍼 매치는 그대로 발화해야 한다 — 게이트는 물리
    /// 폴백만 끄고 composed 경로는 한 글자도 바꾸지 않음을 증명한다(영문/ABC 불변).
    func testComposedMatchStillFiresWhenGateFalse() {
        let m = makeMatcher([snippet(";clear", "CLEARED")])
        var layout = LayoutBuffer()
        let keys: [(String, Character)] =
            [(";", ";"), ("c", "c"), ("l", "l"), ("e", "e"), ("a", "a"), ("r", "r")]
        for (composed, physical) in keys {
            layout.appendLiteral(composed: composed, physical: physical)
        }
        let decision = LayoutAwareMatcher.decide(
            composedBuffer: ";clear", layout: layout, matcher: m,
            allowPhysicalFallback: false
        )
        XCTAssertEqual(decision?.source, .composed)
        XCTAssertEqual(decision?.match.snippet.abbreviation, ";clear")
        XCTAssertEqual(decision?.backspaces, 6)
    }

    /// 약어가 없으면 어느 버퍼로도 발화하지 않는다.
    func testNoMatchReturnsNil() {
        let m = makeMatcher([snippet(";clear", "CLEARED")])
        var layout = LayoutBuffer()
        for (c, p) in [("x", Character("x")), ("y", Character("y"))] {
            layout.appendLiteral(composed: c, physical: p)
        }
        XCTAssertNil(LayoutAwareMatcher.decide(
            composedBuffer: "xy", layout: layout, matcher: m,
            allowPhysicalFallback: true
        ))
    }

    // MARK: - 재현 테스트(수정 전 반드시 실패)

    /// 실기에서 `.listenOnly` 이벤트 탭은 IME의 화면 완성형이 아니라 키마다 낱개
    /// '호환 자모'(U+31xx)를 돌려준다. 이 자모들은 NFC로 합쳐지지 않으므로, 화면 조합
    /// 버퍼에 의존한 옛 계산(precomposedStringWithCanonicalMapping.count)은 물리 키
    /// 6개를 그대로 6으로 센다. 실제 화면은 ";칟ㅁㄱ" 4글자다. 물리 키에서 결정론적
    /// 오토마톤으로 계산하면 4가 나와야 한다. (수정 전: 6 반환 → 실패)
    func testVisibleGraphemeCountFromRealHardwarePhysicalKeysIsFour() {
        var layout = LayoutBuffer()
        // 실기가 돌려주는 호환 자모(합쳐지지 않음)를 composed로 흉내낸다.
        let realHardwareComposed = [";", "ㅊ", "ㅣ", "ㄷ", "ㅁ", "ㄱ"]
        let physicalKeys: [Character] = [";", "c", "l", "e", "a", "r"]
        for i in physicalKeys.indices {
            layout.appendLiteral(composed: realHardwareComposed[i], physical: physicalKeys[i])
        }
        // 화면에는 ";칟ㅁㄱ" 4글자가 찍힌다 → 백스페이스는 4여야 한다.
        XCTAssertEqual(layout.visibleGraphemeCount(lastKeystrokes: 6), 4)
    }

    // MARK: - 삭제 수(화면 글자 기준) 계산

    /// 물리 키 수가 아니라 '화면에 보이는 글자 수'로 삭제해야 한다는 핵심 규칙.
    /// 삭제 수는 IME가 방출한 문자가 아니라, 물리 키를 두벌식 오토마톤에 통과시켜
    /// 결정론적으로 계산한다. 물리 키 6키(";clear")는 화면에 ";칟ㅁㄱ" 4글자를 만든다.
    func testVisibleGraphemeCountUsesPhysicalKeyAutomaton() {
        var layout = LayoutBuffer()
        // composed에 무엇이 오든(실기의 호환 자모든 조합용 jamo든) 결과는 물리 키로 결정된다.
        let composedJamo = [";", jamoC, jamoL, jamoE, jamoA, jamoR]
        let physicalKeys: [Character] = [";", "c", "l", "e", "a", "r"]
        for i in physicalKeys.indices {
            layout.appendLiteral(composed: composedJamo[i], physical: physicalKeys[i])
        }
        XCTAssertEqual(layout.physical, ";clear")
        // 물리 6키 → 화면 4글자(";칟ㅁㄱ": r→ㄱ이라 ㅁ·ㄱ이 낱자로 남는다).
        XCTAssertEqual(layout.visibleGraphemeCount(lastKeystrokes: 6), 4)
        // 끝 2키(a,r → ㅁ,ㄱ)만 보면 두 자음이 각각 낱자로 남아 화면상 2글자.
        XCTAssertEqual(layout.visibleGraphemeCount(lastKeystrokes: 2), 2)
        // 0글자 요청은 0.
        XCTAssertEqual(layout.visibleGraphemeCount(lastKeystrokes: 0), 0)
    }

    /// deleteLast/clear가 물리 버퍼를 올바르게 되돌린다.
    func testDeleteLastAndClear() {
        var layout = LayoutBuffer()
        for (c, p) in [("a", Character("a")), ("b", Character("b")), ("c", Character("c"))] {
            layout.appendLiteral(composed: c, physical: p)
        }
        XCTAssertEqual(layout.physical, "abc")
        layout.deleteLast()
        XCTAssertEqual(layout.physical, "ab")
        layout.clear()
        XCTAssertTrue(layout.isEmpty)
        XCTAssertEqual(layout.physical, "")
    }

    /// maxCount 초과 시 앞에서부터 잘려 최근 키만 유지한다(표시 버퍼 truncation과 짝).
    func testTruncationKeepsMostRecentKeystrokes() {
        var layout = LayoutBuffer(maxCount: 3)
        for ch in "abcde" {
            layout.appendLiteral(composed: String(ch), physical: ch)
        }
        XCTAssertEqual(layout.physical, "cde")
        XCTAssertEqual(layout.count, 3)
    }
}
