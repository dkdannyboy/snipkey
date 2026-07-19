import Foundation

/// 사용자가 고를 수 있는 UI 언어. `.system`은 macOS 선호 언어를 따르고, 나머지는
/// 그 언어로 고정한다. rawValue는 UserDefaults에 저장되므로 절대 바꾸면 안 된다 —
/// 바꾸면 기존 사용자의 언어 선택이 조용히 초기화된다.
public enum AppLanguage: String, CaseIterable, Identifiable, Sendable {
    case system
    case en
    case ko
    case ja

    public var id: String { rawValue }

    /// 각 언어의 자기 이름(endonym). 언어 목록에서는 어떤 UI 언어로 보든 각 항목을
    /// 그 언어의 이름으로 보여주는 것이 관례다(예: 영어 UI에서도 "한국어"로 표시).
    /// `.system`만은 현지화가 필요하므로 여기서 비워 두고 UI가 채운다.
    public var endonym: String {
        switch self {
        case .system: return ""
        case .en: return "English"
        case .ko: return "한국어"
        case .ja: return "日本語"
        }
    }
}

/// 시스템 선호 언어 목록과 사용자 선택으로부터 실효 언어 코드(en/ko/ja)를 계산하는
/// 순수 함수 묶음. UI에서 떼어 낸 이유는 단 하나 — 앱을 띄우지 않고 값만으로 테스트가
/// 닿게 하기 위해서다. 즉시-전환 기능 전체가 이 계산의 정확성에 얹혀 있다.
public enum LanguageResolver {

    /// 카탈로그가 실제로 제공하는 언어. 이 목록에 없는 선호 언어는 건너뛴다.
    public static let supported = ["en", "ko", "ja"]

    /// - Parameters:
    ///   - preferredLanguages: `Locale.preferredLanguages` 같은 우선순위 목록. 각 항목은
    ///     "ko-KR"처럼 지역 태그를 달고 올 수 있어 기본 언어로 접어서 비교한다.
    ///   - selection: 사용자가 설정에서 고른 값.
    /// - Returns: en/ko/ja 중 하나. 어떤 경우에도 지원 언어를 벗어나지 않는다.
    public static func effectiveLanguageCode(
        preferredLanguages: [String],
        selection: AppLanguage
    ) -> String {
        switch selection {
        case .en: return "en"
        case .ko: return "ko"
        case .ja: return "ja"
        case .system:
            for language in preferredLanguages {
                // "ko-KR" → "ko". BCP-47 태그의 첫 서브태그가 언어다.
                let base = language.split(separator: "-").first.map(String.init)?.lowercased()
                    ?? language.lowercased()
                if supported.contains(base) { return base }
            }
            // 지원 언어가 하나도 없으면 안전한 기본값. defaultLocalization과 일치한다.
            return "en"
        }
    }
}
