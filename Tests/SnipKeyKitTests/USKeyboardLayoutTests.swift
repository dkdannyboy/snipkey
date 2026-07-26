import XCTest
import Carbon.HIToolbox
@testable import SnipKeyKit

/// `USKeyboardLayout.character(forKeyCode:shift:)`의 물리 키 → US/ANSI 문자 매핑.
///
/// 이 함수는 IME 독립 물리 매칭의 토대다. 한글 IME가 켜져 있어도 물리 키코드는
/// 반드시 고정된 US 배열로 해석돼야 하며, 그 규칙은 순수·결정적이라 여기서 전부
/// 검증할 수 있다.
final class USKeyboardLayoutTests: XCTestCase {

    /// 과제 명세의 핵심 매핑: 약어 ";clear"를 이루는 글자들.
    func testLettersMapToLowercase() {
        XCTAssertEqual(USKeyboardLayout.character(forKeyCode: kVK_ANSI_C), "c")
        XCTAssertEqual(USKeyboardLayout.character(forKeyCode: kVK_ANSI_L), "l")
        XCTAssertEqual(USKeyboardLayout.character(forKeyCode: kVK_ANSI_E), "e")
        XCTAssertEqual(USKeyboardLayout.character(forKeyCode: kVK_ANSI_A), "a")
        XCTAssertEqual(USKeyboardLayout.character(forKeyCode: kVK_ANSI_R), "r")
    }

    /// 약어에 흔히 쓰는 구두점.
    func testPunctuationUsedInAbbreviations() {
        XCTAssertEqual(USKeyboardLayout.character(forKeyCode: kVK_ANSI_Semicolon), ";")
        XCTAssertEqual(USKeyboardLayout.character(forKeyCode: kVK_ANSI_Slash), "/")
        XCTAssertEqual(USKeyboardLayout.character(forKeyCode: kVK_ANSI_Minus), "-")
        XCTAssertEqual(USKeyboardLayout.character(forKeyCode: kVK_ANSI_Period), ".")
    }

    /// 숫자열.
    func testDigits() {
        XCTAssertEqual(USKeyboardLayout.character(forKeyCode: kVK_ANSI_0), "0")
        XCTAssertEqual(USKeyboardLayout.character(forKeyCode: kVK_ANSI_9), "9")
    }

    /// 스페이스도 매핑된다 — 맨몸 약어의 종결자로 쓰인다.
    func testSpaceMaps() {
        XCTAssertEqual(USKeyboardLayout.character(forKeyCode: kVK_Space), " ")
    }

    /// Shift는 대문자와 시프트 기호를 만든다. 대소문자 구분 약어와 ':' 같은
    /// 시프트 구두점을 물리로도 재현할 수 있어야 한다.
    func testShiftProducesUppercaseAndSymbols() {
        XCTAssertEqual(USKeyboardLayout.character(forKeyCode: kVK_ANSI_C, shift: true), "C")
        XCTAssertEqual(USKeyboardLayout.character(forKeyCode: kVK_ANSI_L, shift: true), "L")
        XCTAssertEqual(USKeyboardLayout.character(forKeyCode: kVK_ANSI_Semicolon, shift: true), ":")
        XCTAssertEqual(USKeyboardLayout.character(forKeyCode: kVK_ANSI_2, shift: true), "@")
        XCTAssertEqual(USKeyboardLayout.character(forKeyCode: kVK_ANSI_Slash, shift: true), "?")
    }

    /// 물리 문자가 없는 키(수정자·편집·기능 키)는 nil을 돌려준다. 엔진은 이때
    /// 물리 버퍼를 비워 재구성 오류를 막는다.
    func testUnmappedKeyCodesReturnNil() {
        XCTAssertNil(USKeyboardLayout.character(forKeyCode: kVK_Return))
        XCTAssertNil(USKeyboardLayout.character(forKeyCode: kVK_Delete))
        XCTAssertNil(USKeyboardLayout.character(forKeyCode: kVK_Escape))
        XCTAssertNil(USKeyboardLayout.character(forKeyCode: kVK_Tab))
    }
}
