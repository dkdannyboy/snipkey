import XCTest
@testable import SnipKeyKit

/// 언어 해석은 앱 재시작 없이 즉시 언어를 바꾸는 기능의 심장이다. UI(NSAlert·Bundle
/// 로딩)에서 떼어 순수 함수로 두었기에 여기서 값만으로 검증할 수 있다.
final class LanguageResolverTests: XCTestCase {

    // MARK: - .system: 선호 목록에서 지원 언어를 고른다

    func testSystemPicksKoreanFromPreferredList() {
        // "ko-KR" 같은 지역 태그도 기본 언어("ko")로 접혀 매칭돼야 한다.
        let code = LanguageResolver.effectiveLanguageCode(
            preferredLanguages: ["ko-KR", "en"],
            selection: .system
        )
        XCTAssertEqual(code, "ko")
    }

    func testSystemFallsBackToEnglishWhenFirstIsUnsupported() {
        // 첫 선호가 미지원("fr")이면 지원 언어("en")까지 내려가 고른다.
        let code = LanguageResolver.effectiveLanguageCode(
            preferredLanguages: ["fr", "en"],
            selection: .system
        )
        XCTAssertEqual(code, "en")
    }

    func testSystemPicksJapanese() {
        let code = LanguageResolver.effectiveLanguageCode(
            preferredLanguages: ["ja"],
            selection: .system
        )
        XCTAssertEqual(code, "ja")
    }

    func testSystemWithNoSupportedLanguageFallsBackToEnglish() {
        // 지원 언어가 하나도 없으면 안전한 기본값 en으로.
        let code = LanguageResolver.effectiveLanguageCode(
            preferredLanguages: ["fr", "de", "es"],
            selection: .system
        )
        XCTAssertEqual(code, "en")
    }

    func testSystemWithEmptyPreferredFallsBackToEnglish() {
        let code = LanguageResolver.effectiveLanguageCode(
            preferredLanguages: [],
            selection: .system
        )
        XCTAssertEqual(code, "en")
    }

    // MARK: - 명시적 선택은 시스템과 무관하게 그 언어를 강제한다

    func testExplicitKoreanOverridesSystem() {
        let code = LanguageResolver.effectiveLanguageCode(
            preferredLanguages: ["en-US", "fr"],
            selection: .ko
        )
        XCTAssertEqual(code, "ko")
    }

    func testExplicitEnglish() {
        let code = LanguageResolver.effectiveLanguageCode(
            preferredLanguages: ["ja-JP"],
            selection: .en
        )
        XCTAssertEqual(code, "en")
    }

    func testExplicitJapanese() {
        let code = LanguageResolver.effectiveLanguageCode(
            preferredLanguages: ["ko-KR"],
            selection: .ja
        )
        XCTAssertEqual(code, "ja")
    }

    // MARK: - 열거형 계약

    func testAllLanguagesHaveStableRawValues() {
        // rawValue는 UserDefaults에 저장되므로 바뀌면 사용자의 선택이 날아간다.
        XCTAssertEqual(AppLanguage.system.rawValue, "system")
        XCTAssertEqual(AppLanguage.en.rawValue, "en")
        XCTAssertEqual(AppLanguage.ko.rawValue, "ko")
        XCTAssertEqual(AppLanguage.ja.rawValue, "ja")
    }

    func testEndonymsAreLanguageNativeNames() {
        XCTAssertEqual(AppLanguage.en.endonym, "English")
        XCTAssertEqual(AppLanguage.ko.endonym, "한국어")
        XCTAssertEqual(AppLanguage.ja.endonym, "日本語")
    }
}
