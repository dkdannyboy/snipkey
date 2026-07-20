import AppKit
import SnipKeyKit

/// 지금 TextExpander가 실행 중인지. NSWorkspace 조회만 앱 레이어에 두고, 판별 규칙은
/// SnipKeyKit의 순수 함수(RunningAppCheck)에 맡겨 테스트 가능하게 한다.
enum TextExpanderDetection {
    static func isRunning() -> Bool {
        NSWorkspace.shared.runningApplications.contains {
            RunningAppCheck.isTextExpander(bundleID: $0.bundleIdentifier, name: $0.localizedName)
        }
    }
}
