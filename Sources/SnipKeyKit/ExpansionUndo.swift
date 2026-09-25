import Foundation

/// 확장 직후의 백스페이스 한 번으로 확장을 되돌리는 계획(Espanso의 undo_backspace).
///
/// SnipKey는 키를 **듣기만** 하므로 사용자의 백스페이스를 삼킬 수 없다. 백스페이스가
/// 앱에 도착해 삽입된 글자 하나를 이미 지운 뒤에야 우리가 반응한다. 그래서 나머지를
/// 지우고, 사용자가 쳤던 약어(와 종결자)를 다시 친다.
public enum ExpansionUndo {

    /// 이보다 긴 확장은 되돌리지 않는다. 백스페이스를 수백 번 쏘는 동안 사용자가 다른 키를
    /// 누르면 가드가 멈추긴 하지만, 그 사이 화면이 요동친다. 그땐 ⌘Z가 낫다.
    public static let maxUndoLength = 400

    public struct Plan: Equatable {
        /// 사용자의 백스페이스 **뒤에** 더 보낼 백스페이스 수.
        public let backspaces: Int
        /// 다시 칠 글자(입력했던 약어 + 종결자).
        public let restore: String
    }

    /// 되돌릴 수 있는 확장이면 계획을, 아니면 nil.
    ///
    /// - Parameters:
    ///   - inserted: 실제로 삽입된 텍스트(종결자 포함).
    ///   - typed: 사용자가 친 약어(종결자 제외). 팔레트 확장은 "".
    ///   - cursorOffsetFromEnd: `%|`로 옮긴 커서 위치. 0이 아니면 백스페이스가 끝이 아닌
    ///     곳을 지웠으므로 되돌릴 수 없다.
    ///   - trailingKeys: `%key:` 뒤따르는 키. Enter·Tab이 이미 눌렸다면 되돌릴 대상이 이미
    ///     떠났다(메시지 전송, 포커스 이동).
    ///   - fromPhysicalLayout: 한글 IME에서 물리 키로 매칭된 확장. 화면의 조합 글자를
    ///     합성 입력으로 똑같이 되살릴 수 없다.
    public static func plan(
        inserted: String,
        typed: String,
        terminator: String,
        cursorOffsetFromEnd: Int,
        trailingKeys: [String],
        fromPhysicalLayout: Bool
    ) -> Plan? {
        guard !typed.isEmpty, !inserted.isEmpty,
              cursorOffsetFromEnd == 0, trailingKeys.isEmpty, !fromPhysicalLayout,
              inserted.count <= maxUndoLength
        else { return nil }
        return Plan(backspaces: inserted.count - 1, restore: typed + terminator)
    }
}
