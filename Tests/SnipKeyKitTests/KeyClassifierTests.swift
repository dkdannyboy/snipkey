import Carbon.HIToolbox
import XCTest
@testable import SnipKeyKit

/// 이벤트 층의 키 분류 계약.
///
/// 종결자로 안전한 키는 '글자를 넣는 것 말고는 아무 일도 하지 않는 키'뿐이다.
/// 스페이스나 마침표가 그렇다. 이벤트 탭이 .listenOnly라 키는 앱에 먼저 도착하는데,
/// 공백 한 칸이 들어갈 뿐이라 그걸 지우고 확장한 뒤 다시 찍으면 그만이다.
///
/// Return과 Tab에는 부작용이 있다. Slack에서 Return은 '전송'이고, 폼에서 Tab은
/// '다음 필드로 이동'이다. 이 키들을 종결자로 받으면 'sig'가 그대로 전송된 뒤
/// 서명이 빈 입력창에 붙거나, 포커스가 옮겨간 옆 칸에 서명이 박힌다. 확장이 안 되는
/// 것보다 잘못된 곳에 확장되는 것이 나쁘다.
///
/// 그래서 분류를 여기서 못 박는다. 누군가 "Return으로도 확장되면 편할 텐데"라며
/// 되돌리려 하면 이 테스트가 막는다.
final class KeyClassifierTests: XCTestCase {

    // MARK: - 종결자가 되어서는 안 되는 키

    /// Return은 앱에 따라 '전송'이다. 종결자로 승격시키면 'sig'가 먼저 날아간다.
    func testReturnClearsBufferAndNeverTerminates() {
        XCTAssertEqual(KeyClassifier.action(forKeyCode: kVK_Return), .clearBuffer)
    }

    /// 키패드 Enter도 Return과 같다. 한쪽만 막으면 절반은 여전히 뚫린다.
    func testKeypadEnterClearsBufferAndNeverTerminates() {
        XCTAssertEqual(KeyClassifier.action(forKeyCode: kVK_ANSI_KeypadEnter), .clearBuffer)
    }

    /// Tab은 폼에서 포커스를 옮긴다. 주입이 나갈 때 커서는 이미 옆 칸에 있다.
    func testTabClearsBufferAndNeverTerminates() {
        XCTAssertEqual(KeyClassifier.action(forKeyCode: kVK_Tab), .clearBuffer)
    }

    /// Escape는 취소다. 확장을 발화시키면 안 된다.
    func testEscapeClearsBufferAndNeverTerminates() {
        XCTAssertEqual(KeyClassifier.action(forKeyCode: kVK_Escape), .clearBuffer)
    }

    /// 화살표·내비게이션 키는 커서를 옮겨서 버퍼와 화면의 대응 관계를 깨뜨린다.
    /// 종결자로 승격시키면 엉뚱한 위치를 백스페이스하게 된다.
    func testNavigationKeysClearBufferAndNeverTerminate() {
        let navigation = [
            kVK_LeftArrow, kVK_RightArrow, kVK_UpArrow, kVK_DownArrow,
            kVK_Home, kVK_End, kVK_PageUp, kVK_PageDown, kVK_ForwardDelete,
        ]
        for keyCode in navigation {
            XCTAssertEqual(KeyClassifier.action(forKeyCode: keyCode), .clearBuffer, "키코드 \(keyCode)")
        }
    }

    /// 부작용이 있는 키는 하나도 남김없이 버퍼를 비워야 한다. 이 목록에 무언가를
    /// 종결자로 추가하려면, 그 키가 앱에 먼저 전달됐을 때 무슨 일이 벌어지는지부터
    /// 답해야 한다.
    func testNoSideEffectKeyIsEverTreatedAsALiteral() {
        let sideEffectKeys = [
            kVK_Return, kVK_ANSI_KeypadEnter, kVK_Tab, kVK_Escape,
            kVK_LeftArrow, kVK_RightArrow, kVK_UpArrow, kVK_DownArrow,
            kVK_Home, kVK_End, kVK_PageUp, kVK_PageDown, kVK_ForwardDelete,
        ]
        for keyCode in sideEffectKeys {
            XCTAssertNotEqual(
                KeyClassifier.action(forKeyCode: keyCode), .literal,
                "키코드 \(keyCode)는 부작용이 있어 버퍼에 글자로 들어가면 안 된다"
            )
        }
    }

    // MARK: - 나머지

    func testBackspaceDeletesLastCharacter() {
        XCTAssertEqual(KeyClassifier.action(forKeyCode: kVK_Delete), .deleteLast)
    }

    /// 스페이스와 구두점은 평범한 글자로 버퍼에 들어간다. 종결자인지 아닌지는
    /// 매처가 판단한다 — 이벤트 층은 '타이핑된 글자'와 '버퍼를 무효화하는 키'만
    /// 구분하면 된다.
    func testOrdinaryCharacterKeysAreLiteral() {
        for keyCode in [kVK_ANSI_A, kVK_ANSI_1, kVK_Space, kVK_ANSI_Period] {
            XCTAssertEqual(KeyClassifier.action(forKeyCode: keyCode), .literal, "키코드 \(keyCode)")
        }
    }

    /// 이벤트 층이 실제로 매처에 넘기는 종결자(스페이스·구두점)는 매처가 받아들여야
    /// 한다. 두 층을 한 테스트로 맞물려 본다 — 이게 깨지면 '유닛은 초록, 앱은 먹통'이다.
    func testTerminatorsTheEngineCanActuallyDeliverAreAcceptedByTheMatcher() {
        let snippet = Snippet(abbreviation: "sig", content: "SIGNATURE-BLOCK", caseSensitive: true)
        let matcher = Store.Matcher(maxLength: 3, exact: ["sig": snippet], insensitive: [:])

        // Return·Tab은 여기 없다. 이벤트 층이 그 키를 매처에 넘기지 않기 때문이다.
        // 매처가 "\n"을 종결자로 받아들일 수는 있지만, 그런 버퍼는 만들어지지 않는다.
        for terminator in [" ", ".", ",", "!", ")", "?"] {
            let match = matcher.match(buffer: "sig" + terminator)
            XCTAssertEqual(match?.snippet.content, "SIGNATURE-BLOCK", "종결자 '\(terminator)'")
            XCTAssertEqual(match?.backspaces, 4, "종결자 '\(terminator)'")  // 약어 3 + 종결자 1
            XCTAssertEqual(match?.terminator, terminator, "종결자 '\(terminator)'")
        }
    }
}
