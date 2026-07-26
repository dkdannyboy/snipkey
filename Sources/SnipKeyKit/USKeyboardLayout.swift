import Carbon.HIToolbox

/// 물리 키코드 → US/ANSI(QWERTY) 라틴 문자.
///
/// TextExpander처럼 '물리 키 위치'로 약어를 매칭하려면, 현재 입력기(IME)가
/// 무엇이든 상관없이 키코드를 고정된 US 배열로 해석해야 한다. 한글 IME가 켜져
/// 있어도 `;clear`를 물리적으로 누르면 US 기준 ";clear"가 나와야 한다.
///
/// UCKeyTranslate를 '현재' 입력 소스로 돌리면 한글이 나와 버리므로 쓸 수 없다.
/// US 배열은 고정 상수이므로, 런타임 Carbon 호출 없이 정적 표로 매핑한다. 그래서
/// 이 함수는 완전히 순수하고 결정적이며 SnipKeyKit 테스트 타깃에서 단위 테스트된다.
///
/// @MX:NOTE: [AUTO] IME 독립 물리 키 해석의 유일한 지점. HotkeyManager의
///           UCKeyTranslate(표시용, 현재 배열)와 목적이 다르다 — 혼동 주의.
public enum USKeyboardLayout {

    /// 물리 키코드를 US/ANSI 문자로 변환한다. 대응하는 라틴 문자가 없으면 nil.
    ///
    /// - Parameters:
    ///   - keyCode: CGEvent의 원시 키코드(`kVK_ANSI_*`, `kVK_Space` 등).
    ///   - shift: Shift 수정자 여부. 대문자·시프트 기호를 만든다.
    public static func character(forKeyCode keyCode: Int, shift: Bool = false) -> Character? {
        if shift, let shifted = shiftedMap[keyCode] { return shifted }
        return baseMap[keyCode]
    }

    /// 시프트 없이 눌렀을 때의 US 배열 문자.
    private static let baseMap: [Int: Character] = [
        kVK_ANSI_A: "a", kVK_ANSI_B: "b", kVK_ANSI_C: "c", kVK_ANSI_D: "d",
        kVK_ANSI_E: "e", kVK_ANSI_F: "f", kVK_ANSI_G: "g", kVK_ANSI_H: "h",
        kVK_ANSI_I: "i", kVK_ANSI_J: "j", kVK_ANSI_K: "k", kVK_ANSI_L: "l",
        kVK_ANSI_M: "m", kVK_ANSI_N: "n", kVK_ANSI_O: "o", kVK_ANSI_P: "p",
        kVK_ANSI_Q: "q", kVK_ANSI_R: "r", kVK_ANSI_S: "s", kVK_ANSI_T: "t",
        kVK_ANSI_U: "u", kVK_ANSI_V: "v", kVK_ANSI_W: "w", kVK_ANSI_X: "x",
        kVK_ANSI_Y: "y", kVK_ANSI_Z: "z",

        kVK_ANSI_0: "0", kVK_ANSI_1: "1", kVK_ANSI_2: "2", kVK_ANSI_3: "3",
        kVK_ANSI_4: "4", kVK_ANSI_5: "5", kVK_ANSI_6: "6", kVK_ANSI_7: "7",
        kVK_ANSI_8: "8", kVK_ANSI_9: "9",

        kVK_ANSI_Semicolon: ";", kVK_ANSI_Quote: "'", kVK_ANSI_Comma: ",",
        kVK_ANSI_Period: ".", kVK_ANSI_Slash: "/", kVK_ANSI_Minus: "-",
        kVK_ANSI_Equal: "=", kVK_ANSI_LeftBracket: "[", kVK_ANSI_RightBracket: "]",
        kVK_ANSI_Backslash: "\\", kVK_ANSI_Grave: "`",

        kVK_Space: " ",
    ]

    /// Shift를 누른 상태의 US 배열 문자. 글자는 대문자, 숫자·기호는 시프트 기호.
    private static let shiftedMap: [Int: Character] = [
        kVK_ANSI_A: "A", kVK_ANSI_B: "B", kVK_ANSI_C: "C", kVK_ANSI_D: "D",
        kVK_ANSI_E: "E", kVK_ANSI_F: "F", kVK_ANSI_G: "G", kVK_ANSI_H: "H",
        kVK_ANSI_I: "I", kVK_ANSI_J: "J", kVK_ANSI_K: "K", kVK_ANSI_L: "L",
        kVK_ANSI_M: "M", kVK_ANSI_N: "N", kVK_ANSI_O: "O", kVK_ANSI_P: "P",
        kVK_ANSI_Q: "Q", kVK_ANSI_R: "R", kVK_ANSI_S: "S", kVK_ANSI_T: "T",
        kVK_ANSI_U: "U", kVK_ANSI_V: "V", kVK_ANSI_W: "W", kVK_ANSI_X: "X",
        kVK_ANSI_Y: "Y", kVK_ANSI_Z: "Z",

        kVK_ANSI_1: "!", kVK_ANSI_2: "@", kVK_ANSI_3: "#", kVK_ANSI_4: "$",
        kVK_ANSI_5: "%", kVK_ANSI_6: "^", kVK_ANSI_7: "&", kVK_ANSI_8: "*",
        kVK_ANSI_9: "(", kVK_ANSI_0: ")",

        kVK_ANSI_Semicolon: ":", kVK_ANSI_Quote: "\"", kVK_ANSI_Comma: "<",
        kVK_ANSI_Period: ">", kVK_ANSI_Slash: "?", kVK_ANSI_Minus: "_",
        kVK_ANSI_Equal: "+", kVK_ANSI_LeftBracket: "{", kVK_ANSI_RightBracket: "}",
        kVK_ANSI_Backslash: "|", kVK_ANSI_Grave: "~",

        kVK_Space: " ",
    ]
}
