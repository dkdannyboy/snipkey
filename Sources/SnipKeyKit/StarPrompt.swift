import Foundation

/// "지금 GitHub 별표를 부탁하는 창을 띄워도 되는가"에 대한 순수 판정.
///
/// UI(NSAlert)와 상태 저장(UserDefaults)은 앱 층에 두고, '언제 띄울지'라는 결정만
/// 여기로 뺀다 — 그래야 테스트가 닿는다. 확장 횟수는 사용자가 앱을 쓰는 동안 다른 앱
/// 안에서 오르므로, 이 판정은 창이 닫혀 있어도 돌아야 한다.
public enum StarPrompt {

    /// 50번째마다(50, 100, 150, …) 별표를 부탁한다. 아직 별표를 누르지 않았고
    /// "다시 묻지 않기"도 고르지 않았을 때만.
    ///
    /// - Parameters:
    ///   - expansionCount: 지금까지의 장치-로컬 확장 횟수.
    ///   - hasStarred: 사용자가 이미 별표를 눌렀는가. 눌렀으면 영원히 안 띄운다.
    ///   - dismissedForever: "다시 묻지 않기"를 골랐는가. 골랐으면 영원히 안 띄운다.
    ///   - lastPromptedCount: 마지막으로 창을 띄웠을 때의 확장 횟수. 같은 값에서 두 번
    ///     띄우지 않게 막는다 — 정확히 50에서 앱을 재실행하거나, 같은 값을 두 번
    ///     관측(Combine이 초기값과 변경값을 겹쳐 흘릴 때)해도 창이 다시 뜨면 안 된다.
    public static func shouldPrompt(
        expansionCount: Int,
        hasStarred: Bool,
        dismissedForever: Bool,
        lastPromptedCount: Int
    ) -> Bool {
        expansionCount > 0
            && expansionCount % 50 == 0
            && !hasStarred
            && !dismissedForever
            && expansionCount != lastPromptedCount
    }
}
