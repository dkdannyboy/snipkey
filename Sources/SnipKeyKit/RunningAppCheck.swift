import Foundation

/// 실행 중인 앱이 TextExpander인지 판별하는 순수 함수. NSWorkspace 조회(앱 레이어)와
/// 분리해 둔 이유는 이 규칙을 앱 없이 단위 테스트로 못 박기 위해서다.
///
/// 왜 필요한가: SnipKey는 TextExpander 대체품이라 이주 중인 사용자는 둘 다 켜 두기
/// 쉽다. 그러면 같은 약어를 둘이 각자 확장해 확장이 두 번 나온다(실제 사용자 사례).
/// 온보딩·가져오기에서 TextExpander가 켜져 있으면 안내하려고 이 판별을 쓴다.
public enum RunningAppCheck {
    /// TextExpander는 버전마다 번들 ID가 다르다(com.smileonmymac.textexpander,
    /// com.textexpander.* 등). 소문자 "textexpander"를 번들 ID에 포함하거나 앱 이름이
    /// TextExpander면 참으로 넓게 잡는다.
    public static func isTextExpander(bundleID: String?, name: String?) -> Bool {
        if let b = bundleID?.lowercased(), b.contains("textexpander") { return true }
        if let n = name?.lowercased(), n.contains("textexpander") { return true }
        return false
    }
}
