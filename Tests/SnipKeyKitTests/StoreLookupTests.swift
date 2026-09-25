import XCTest
@testable import SnipKeyKit

/// 중첩 조회(B4), 검색 팔레트의 비활성 제외(B2), 복제 약어 이름 짓기(B3).
final class StoreLookupTests: XCTestCase {

    private var dir: URL!

    override func setUp() {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("snipkey-lookup-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)
    }

    private func makeStore(_ groups: [SnippetGroup]) -> Store {
        let defaults = UserDefaults(suiteName: "snipkey-lookup-\(UUID().uuidString)")!
        let store = Store(fileURL: dir.appendingPathComponent("store.json"), deviceDefaults: defaults)
        store.groups = groups
        return store
    }

    // MARK: - B4: 중첩 조회는 실제 확장과 같은 규칙을 먼저 따른다

    func testNestedLookupPrefersEnabledSnippet() {
        let off = Snippet(abbreviation: ";x", content: "disabled", enabled: false)
        let on = Snippet(abbreviation: ";x", content: "enabled")
        let store = makeStore([SnippetGroup(name: "g", snippets: [off, on])])
        XCTAssertEqual(store.snippet(forAbbreviation: ";x")?.content, "enabled")
    }

    func testNestedLookupHonoursCaseInsensitiveSnippet() {
        let s = Snippet(abbreviation: ";Addr", content: "Seoul", caseSensitive: false)
        let store = makeStore([SnippetGroup(name: "g", snippets: [s])])
        XCTAssertEqual(store.snippet(forAbbreviation: ";addr")?.content, "Seoul")
    }

    // MARK: - B2: 검색 팔레트는 비활성 스니펫을 내놓지 않는다

    func testPaletteSearchExcludesDisabled() {
        let on = Snippet(abbreviation: ";sig1", content: "a")
        let off = Snippet(abbreviation: ";sig2", content: "b", enabled: false)
        let offGroup = SnippetGroup(name: "off", enabled: false, snippets: [Snippet(abbreviation: ";sig3", content: "c")])
        let store = makeStore([SnippetGroup(name: "g", snippets: [on, off]), offGroup])
        XCTAssertEqual(store.search("sig", includeDisabled: false).map(\.snippet.abbreviation), [";sig1"])
        XCTAssertEqual(store.search("sig").count, 3, "편집기 검색은 예전처럼 전부 보여 준다")
    }

    // MARK: - B3: 복제본 약어

    func testDuplicateAbbreviationPicksFreeSuffix() {
        let taken: Set<String> = [";sig", ";sig2"]
        XCTAssertEqual(AbbreviationNaming.duplicate(of: ";sig", taken: taken), ";sig3")
    }

    func testDuplicateOfEmptyAbbreviationStaysEmpty() {
        // 예전에는 "2"가 되어 '2 '를 칠 때마다 확장됐다.
        XCTAssertEqual(AbbreviationNaming.duplicate(of: "", taken: [""]), "")
    }
}
