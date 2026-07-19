import Foundation
import Combine
import SnipKeyKit

extension Notification.Name {
    /// UI 언어가 바뀌면 쏜다. SwiftUI는 @Published로 자동 갱신되지만, AppKit으로 만든
    /// 메인 메뉴는 값 관찰을 하지 않으므로 이 알림을 받아 다시 그려야 한다.
    static let snipKeyLanguageChanged = Notification.Name("snipkey.language.changed")
}

/// 앱 전역 현지화 관리자. `language`를 바꾸면:
///   (a) @Published가 objectWillChange를 쏘아 모든 SwiftUI 뷰가 즉시 다시 그려지고,
///   (b) .snipKeyLanguageChanged 알림으로 AppKit 메인 메뉴를 다시 그리게 한다.
/// 상태바 메뉴는 열릴 때마다 새로 만들어지므로(menuNeedsUpdate) 자동으로 최신이고,
/// NSAlert류(별점·확인창)는 표시 시점에 `s(_:)`를 읽으므로 역시 자동으로 맞는다.
final class LocalizationManager: ObservableObject {

    /// 사용자가 고른 언어. 장치-로컬이다 — 언어 취향은 Mac마다 다를 수 있고, 동기화되는
    /// 문서(store.json)에 섞이면 안 되므로 확장 횟수·온보딩 플래그와 같은 패턴을 따른다.
    @Published var language: AppLanguage {
        didSet {
            deviceDefaults.set(language.rawValue, forKey: Self.deviceKey)
            rebuildBundle()
            NotificationCenter.default.post(name: .snipKeyLanguageChanged, object: nil)
        }
    }

    static let deviceKey = "SnipKey.device.uiLanguage"

    private let deviceDefaults: UserDefaults
    /// 현재 실효 언어의 .lproj 번들. Bundle.module 전체가 아니라 특정 언어 번들을 직접
    /// 골라 잡는 이유는 즉시-전환 때문이다 — macOS 표준 번들 조회는 실행 시점의 시스템
    /// 언어에 고정되어, 앱을 재시작하지 않고서는 다른 언어 테이블을 읽어 주지 않는다.
    private var bundle: Bundle

    init(deviceDefaults: UserDefaults = .standard) {
        self.deviceDefaults = deviceDefaults
        let stored = deviceDefaults.string(forKey: Self.deviceKey)
        let initial = stored.flatMap(AppLanguage.init(rawValue:)) ?? .system
        self.language = initial
        self.bundle = .module
        rebuildBundle()
    }

    /// 실효 언어를 다시 계산해 대응하는 .lproj 번들을 잡는다.
    private func rebuildBundle() {
        let code = LanguageResolver.effectiveLanguageCode(
            preferredLanguages: Locale.preferredLanguages,
            selection: language
        )
        if let url = Bundle.module.url(forResource: code, withExtension: "lproj"),
           let localized = Bundle(url: url) {
            bundle = localized
        } else {
            // lproj를 못 찾으면 최소한 기본 번들로 떨어져 키 대신 en 문자열이 나오게 한다.
            bundle = .module
        }
    }

    /// 현지화 문자열 조회. 키가 없으면 값으로 준 키 자체를 돌려주므로(디버그에 유용),
    /// 릴리스에서 그런 일이 없도록 키-패리티 테스트가 세 언어를 강제한다.
    /// - Parameters:
    ///   - key: 카탈로그 키.
    ///   - args: 포맷 인자(%@, %d 등). 비어 있으면 String(format:)을 건너뛰어, 인자가
    ///     없는 문자열(예: "%filltext:…%"가 들어간 팁)의 %가 오해석되지 않게 한다.
    func s(_ key: String, _ args: CVarArg...) -> String {
        let format = bundle.localizedString(forKey: key, value: key, table: nil)
        if args.isEmpty { return format }
        return String(format: format, arguments: args)
    }

    /// 언어 목록에서 각 항목에 보여줄 이름. `.system`은 현지화된 "시스템 기본값"으로,
    /// 나머지는 그 언어의 자기 이름(endonym)으로 — 어떤 UI 언어로 보든 관례에 맞게.
    func displayName(for language: AppLanguage) -> String {
        language == .system ? s("settings.language.systemDefault") : language.endonym
    }
}
