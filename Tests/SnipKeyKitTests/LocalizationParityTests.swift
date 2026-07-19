import XCTest

/// 반쯤 번역된 릴리스를 막는 감시견. en/ko/ja 세 카탈로그의 키 집합이 정확히 같아야
/// 한다 — 한 언어에만 있는 키는 곧 다른 언어에서 영어(키)가 그대로 새어 나온다는 뜻이다.
///
/// 리소스는 SnipKey(실행) 타깃에 있어 SnipKeyKitTests가 번들로 접근할 수 없으므로,
/// `#file` 기준으로 소스 트리의 .strings 파일을 직접 읽어 파싱한다.
final class LocalizationParityTests: XCTestCase {

    private let languages = ["en", "ko", "ja"]

    /// 이 테스트 파일에서 리포지토리 루트로 거슬러 올라간다:
    /// Tests/SnipKeyKitTests/LocalizationParityTests.swift → 3단계 위가 루트.
    private var repoRoot: URL {
        URL(fileURLWithPath: #file)
            .deletingLastPathComponent()   // SnipKeyKitTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // repo root
    }

    private func stringsURL(for language: String) -> URL {
        repoRoot
            .appendingPathComponent("Sources/SnipKey/Resources")
            .appendingPathComponent("\(language).lproj")
            .appendingPathComponent("Localizable.strings")
    }

    private func loadKeys(_ language: String) throws -> Set<String> {
        let url = stringsURL(for: language)
        let raw = try String(contentsOf: url, encoding: .utf8)
        // .strings 전용 파서. old-style plist 형식("key" = "value";)을 정확히 다룬다.
        guard let dict = (raw as NSString).propertyListFromStringsFileFormat() as? [String: String] else {
            XCTFail("Could not parse \(url.path) as a .strings file")
            return []
        }
        return Set(dict.keys)
    }

    func testEveryLanguageHasIdenticalKeySets() throws {
        let english = try loadKeys("en")
        XCTAssertFalse(english.isEmpty, "en catalog should not be empty")

        for language in languages where language != "en" {
            let other = try loadKeys(language)
            let missing = english.subtracting(other)
            let extra = other.subtracting(english)
            XCTAssertTrue(
                missing.isEmpty,
                "\(language) is MISSING keys present in en: \(missing.sorted())"
            )
            XCTAssertTrue(
                extra.isEmpty,
                "\(language) has EXTRA keys absent from en: \(extra.sorted())"
            )
        }
    }

    /// 세 언어 모두 값이 비어 있지 않아야 한다(빈 문자열은 사실상 미번역).
    func testNoLanguageHasEmptyValues() throws {
        for language in languages {
            let url = stringsURL(for: language)
            let raw = try String(contentsOf: url, encoding: .utf8)
            guard let dict = (raw as NSString).propertyListFromStringsFileFormat() as? [String: String] else {
                XCTFail("Could not parse \(url.path)")
                continue
            }
            let empties = dict.filter { $0.value.isEmpty }.keys.sorted()
            XCTAssertTrue(empties.isEmpty, "\(language) has empty values for: \(empties)")
        }
    }
}
