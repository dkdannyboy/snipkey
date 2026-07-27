import XCTest
@testable import SnipKeyKit

/// 물리 버퍼 폴백 게이트의 순수 술어 `isTwoSetKoreanSourceID`.
///
/// 물리 키 삭제 수 계산이 두벌식 전용 오토마톤(HangulComposer)에 묶여 있으므로,
/// 물리 폴백은 '정확히' 두벌식(com.apple.inputmethod.Korean.2SetKorean)에서만
/// 허용해야 한다. 세벌식·일본어·중국어·라틴·미지 IME는 모두 제외(false)다.
/// 실기(일본어/중국어 IME)로는 E2E 검증이 어려우므로, 이 단위 테스트가 억제
/// 범위를 대신 보증한다.
final class InputSourceGateTests: XCTestCase {

    /// 두벌식 정확 일치만 true.
    func testTwoSetKoreanIsAllowed() {
        XCTAssertTrue(isTwoSetKoreanSourceID("com.apple.inputmethod.Korean.2SetKorean"))
    }

    /// 세벌식 계열은 물리 키가 다른 jamo로 매핑되므로 반드시 false(오삭제 방지).
    func testThreeSetKoreanIsDisallowed() {
        XCTAssertFalse(isTwoSetKoreanSourceID("com.apple.inputmethod.Korean.3SetKorean"))
        XCTAssertFalse(isTwoSetKoreanSourceID("com.apple.inputmethod.Korean.390Korean"))
    }

    /// 조합형 IME(일본어 로마자·중국어 병음)는 조합 중 오확장 위험 → false.
    func testComposingImesAreDisallowed() {
        XCTAssertFalse(isTwoSetKoreanSourceID("com.apple.inputmethod.Kotoeri.Japanese"))
        XCTAssertFalse(isTwoSetKoreanSourceID("com.apple.inputmethod.SCIM.ITABC"))
    }

    /// 라틴 배열(ABC/US)은 두 버퍼가 동일해 게이트와 무관 → false여도 동작 불변.
    func testLatinLayoutsAreDisallowed() {
        XCTAssertFalse(isTwoSetKoreanSourceID("com.apple.keylayout.ABC"))
        XCTAssertFalse(isTwoSetKoreanSourceID("com.apple.keylayout.US"))
    }

    /// TIS가 ID를 못 읽어 빈 문자열이 오면 페일세이프로 false(물리 폴백 OFF).
    func testEmptyIsDisallowed() {
        XCTAssertFalse(isTwoSetKoreanSourceID(""))
    }

    /// 접두사만 같은 유사 ID도 정확 일치가 아니면 false(느슨한 매칭 금지).
    func testPrefixLookalikeIsDisallowed() {
        XCTAssertFalse(isTwoSetKoreanSourceID("com.apple.inputmethod.Korean.2SetKoreanX"))
        XCTAssertFalse(isTwoSetKoreanSourceID("com.apple.inputmethod.Korean"))
    }
}
