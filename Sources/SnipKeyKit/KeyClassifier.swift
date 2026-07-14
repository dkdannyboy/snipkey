import Carbon.HIToolbox

/// 키 하나가 확장 버퍼에 무엇을 하는지.
///
/// 이 결정을 엔진 안의 switch 문에 묻어두면 단위 테스트가 닿지 못한다. 매처는
/// "\n"과 "\t"를 정당한 종결자로 받아들이는데 정작 이벤트 층이 그 키를 매처에
/// 넘기지 않는다면, 매처 테스트는 통과하면서 사용자는 확장을 못 보는 상태가 된다.
/// 그 간극을 테스트로 막을 수 있도록 분류 자체를 값으로 꺼낸다.
public enum KeyAction: Equatable {
    /// 백스페이스 — 버퍼의 마지막 글자를 지운다.
    case deleteLast
    /// 버퍼를 무효화하는 키. 취소(Escape), 커서 이동, 그리고 부작용 때문에
    /// 종결자로 쓸 수 없는 Return·Tab이 여기 속한다.
    case clearBuffer
    /// 그 밖의 키. 실제로 타이핑된 문자를 버퍼에 붙인다. 스페이스와 구두점도
    /// 여기로 들어오며, 종결자인지 아닌지는 매처가 판단한다.
    case literal
}

/// 키코드 → 버퍼 동작. 엔진의 유일한 키 분류 지점이다.
public enum KeyClassifier {

    public static func action(forKeyCode keyCode: Int) -> KeyAction {
        switch keyCode {
        case kVK_Delete:
            return .deleteLast

        // Return·Tab은 단어를 끝내지만 종결자로 쓸 수 없다.
        //
        // 종결자로 안전한 키는 '글자를 넣는 것 말고는 아무 일도 하지 않는 키'뿐이다.
        // 스페이스나 마침표가 그렇다. 그 키가 앱에 먼저 전달돼도 공백 한 칸이
        // 들어갈 뿐이고, 우리는 그걸 지우고 확장한 뒤 다시 찍으면 그만이다.
        //
        // Return과 Tab은 다르다. 이벤트 탭이 .listenOnly라 키가 앱에 먼저 도착하는데,
        // 그 키에는 부작용이 있다:
        //   - Slack·메시지·검색창에서 Return은 '전송'이다. 'sig' 뒤에 Return을 종결자로
        //     받으면 'sig'가 그대로 전송된 뒤, 확장된 서명이 비어버린 입력창에 붙는다.
        //   - 웹·네이티브 폼에서 Tab은 '다음 필드로 포커스 이동'이다. 백스페이스와
        //     붙여넣기가 나갈 때 커서는 이미 옆 칸에 있다. 서명이 엉뚱한 칸에 박힌다.
        // TextInjector는 PID로만 대상 앱을 지키므로 포커스가 옮겨간 컨트롤까지는 막지 못한다.
        //
        // 확장이 안 되는 것보다 잘못된 곳에 확장되는 것이 나쁘다. 그래서 버퍼를 비운다.
        // 맨몸 약어를 즉시 마무리하고 싶으면 스페이스나 구두점을 치거나, 애초에
        // 구두점으로 시작하는 약어(';sig')를 쓰면 된다 — 그쪽은 종결자를 기다리지 않는다.
        //
        // 제대로 지원하려면 .listenOnly가 아닌 가로채는 탭(.defaultTap)으로 바꿔서
        // 종결자 키를 삼켰다가 주입 후에 다시 쏴야 한다. 모든 키 입력 경로에 영향을
        // 주는 변경이라 별도 과제로 남긴다.
        //
        // Escape는 '취소'이고, 화살표·내비게이션 키는 커서를 옮겨 버퍼와 화면의
        // 대응 관계를 깨뜨린다. 이들도 종결자가 되어서는 안 된다.
        case kVK_Return, kVK_ANSI_KeypadEnter, kVK_Tab,
             kVK_Escape,
             kVK_LeftArrow, kVK_RightArrow, kVK_UpArrow, kVK_DownArrow,
             kVK_Home, kVK_End, kVK_PageUp, kVK_PageDown, kVK_ForwardDelete:
            return .clearBuffer

        default:
            return .literal
        }
    }
}
