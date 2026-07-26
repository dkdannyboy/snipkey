import XCTest
@testable import SnipKeyKit

/// 물리 QWERTY 키 → 두벌식 화면 글자 재구성 오토마톤.
///
/// 삭제 백스페이스 수의 근원이므로, 조합 규칙(초성/중성/종성, 겹모음, 겹받침,
/// 끝소리 빼앗기)과 비-자모 처리를 폭넓게 검증한다. 순수 함수라 이벤트 탭 없이 돈다.
final class HangulComposerTests: XCTestCase {

    private func compose(_ keys: String) -> String {
        HangulComposer.compose(physicalKeys: Array(keys))
    }
    private func count(_ keys: String) -> Int {
        HangulComposer.glyphCount(physicalKeys: Array(keys))
    }

    // MARK: - 물리 키 → 자모 매핑

    func testUnshiftedJamoMapping() {
        XCTAssertEqual(HangulComposer.jamo(for: "r"), "ㄱ")  // 두벌식 r은 ㄱ (ㅏ 아님)
        XCTAssertEqual(HangulComposer.jamo(for: "k"), "ㅏ")
        XCTAssertEqual(HangulComposer.jamo(for: "c"), "ㅊ")
        XCTAssertEqual(HangulComposer.jamo(for: "m"), "ㅡ")
    }

    func testShiftedJamoMapping() {
        XCTAssertEqual(HangulComposer.jamo(for: "Q"), "ㅃ")
        XCTAssertEqual(HangulComposer.jamo(for: "R"), "ㄲ")
        XCTAssertEqual(HangulComposer.jamo(for: "O"), "ㅒ")
        // 시프트가 자모를 바꾸지 않는 글자는 소문자 매핑을 따른다.
        XCTAssertEqual(HangulComposer.jamo(for: "A"), "ㅁ")
        XCTAssertEqual(HangulComposer.jamo(for: "K"), "ㅏ")
    }

    func testNonJamoKeysReturnNil() {
        for ch in Array(";'1 ,.-") {
            XCTAssertNil(HangulComposer.jamo(for: ch), "\(ch)는 자모가 아니어야 한다")
        }
    }

    // MARK: - 기본 조합

    func testSingleConsonantIsStandalone() {
        XCTAssertEqual(compose("r"), "ㄱ")   // 초성만 → 낱자 ㄱ
        XCTAssertEqual(count("r"), 1)
    }

    func testSingleVowelIsStandalone() {
        XCTAssertEqual(compose("k"), "ㅏ")   // 중성만 → 낱자 ㅏ
        XCTAssertEqual(count("k"), 1)
    }

    func testChoJungSyllable() {
        XCTAssertEqual(compose("rk"), "가")   // ㄱ + ㅏ
        XCTAssertEqual(count("rk"), 1)
    }

    func testChoJungJongSyllable() {
        XCTAssertEqual(compose("rkr"), "각")  // ㄱ + ㅏ + ㄱ(종성)
        XCTAssertEqual(count("rkr"), 1)
    }

    func testTwoConsonantsStayTwoGlyphs() {
        XCTAssertEqual(compose("rr"), "ㄱㄱ")  // 자음+자음(모음 없음) → 낱자 둘
        XCTAssertEqual(count("rr"), 2)
    }

    // MARK: - 겹모음 / 겹받침

    func testCompoundMedial() {
        // g→ㅎ h→ㅗ k→ㅏ : ㅗ+ㅏ=ㅘ → 화
        XCTAssertEqual(compose("ghk"), "화")
        XCTAssertEqual(count("ghk"), 1)
    }

    func testCompoundFinal() {
        // r→ㄱ k→ㅏ r→ㄱ t→ㅅ : 종성 ㄱ+ㅅ=ㄳ → 갃
        XCTAssertEqual(compose("rkrt"), "갃")
        XCTAssertEqual(count("rkrt"), 1)
    }

    // MARK: - 끝소리 빼앗기

    func testSimpleFinalStealing() {
        // r→ㄱ k→ㅏ d→ㅇ k→ㅏ : 강 뒤 ㅏ가 종성 ㅇ을 초성으로 빼앗아 "가아"
        XCTAssertEqual(compose("rkdk"), "가아")
        XCTAssertEqual(count("rkdk"), 2)
    }

    func testCompoundFinalStealing() {
        // r→ㄱ k→ㅏ r→ㄱ t→ㅅ k→ㅏ : 갃(종성 ㄳ) 뒤 ㅏ → ㄱ은 종성으로 남고 ㅅ이 초성으로.
        // 각 + 사 = "각사"
        XCTAssertEqual(compose("rkrtk"), "각사")
        XCTAssertEqual(count("rkrtk"), 2)
    }

    // MARK: - 비-자모 혼합

    func testNonJamoBreaksSyllableAndCountsOne() {
        // rk("가") + ";" + rk("가")
        XCTAssertEqual(compose("rk;rk"), "가;가")
        XCTAssertEqual(count("rk;rk"), 3)
    }

    func testPunctuationOnly() {
        XCTAssertEqual(compose(";"), ";")
        XCTAssertEqual(count(";"), 1)
    }

    // MARK: - 핵심 회귀 케이스: ";clear"

    /// 실기 버그의 정답. 물리 ";clear"(6키)는 화면에 ";칟ㅁㄱ" 4글자를 만든다.
    ///   ; = 낱자(1) / c,l,e = ㅊㅣㄷ = 칟(1) / a = ㅁ(초성, 낱자로 남음) / r = ㄱ(초성, 낱자)
    /// 따라서 백스페이스는 6이 아니라 4다.
    func testSemicolonClearProducesFourGlyphs() {
        XCTAssertEqual(compose(";clear"), ";칟ㅁㄱ")
        XCTAssertEqual(count(";clear"), 4)
    }
}
