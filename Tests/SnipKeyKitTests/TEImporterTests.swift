import XCTest
@testable import SnipKeyKit

final class TEImporterTests: XCTestCase {

    var fixtureFolder: URL {
        Bundle.module.resourceURL!.appendingPathComponent("Fixtures")
    }

    func testImportFixtureFolder() throws {
        let result = try TEImporter.importFolder(fixtureFolder)
        XCTAssertEqual(result.groups.count, 1)
        let group = result.groups[0]
        XCTAssertEqual(group.name, "Fixture Group")
        XCTAssertEqual(group.snippets.count, 2)

        let first = group.snippets.first { $0.abbreviation == "~fx1" }
        XCTAssertNotNil(first)
        XCTAssertEqual(first?.content, "fixture expansion one")
        XCTAssertEqual(first?.caseSensitive, true)

        // Snippet with an empty abbreviation must be skipped.
        XCTAssertEqual(result.skippedEmptyAbbrev, 1)
    }

    func testImportMissingFolderThrows() {
        XCTAssertThrowsError(
            try TEImporter.importFolder(URL(fileURLWithPath: "/nonexistent/path"))
        )
    }

    func testStoreMergeReplacesSameNameGroup() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("snipkey-test-\(UUID().uuidString).json")
        let store = Store(fileURL: tmp)
        store.groups = [SnippetGroup(name: "A", snippets: [Snippet(abbreviation: ";old", content: "old")])]
        store.mergeImported(groups: [SnippetGroup(name: "A", snippets: [Snippet(abbreviation: ";new", content: "new")])])
        XCTAssertEqual(store.groups.count, 1)
        XCTAssertEqual(store.groups[0].snippets.map(\.abbreviation), [";new"])
        try? FileManager.default.removeItem(at: tmp)
    }

    func testMatcherLongestSuffixWins() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("snipkey-test-\(UUID().uuidString).json")
        let store = Store(fileURL: tmp)
        store.groups = [SnippetGroup(name: "G", snippets: [
            Snippet(abbreviation: "ddd", content: "long"),
            Snippet(abbreviation: "dd", content: "short"),
        ])]
        XCTAssertEqual(store.matcher.match(buffer: "xxddd")?.content, "long")
        XCTAssertEqual(store.matcher.match(buffer: "xxadd")?.content, "short")
        XCTAssertNil(store.matcher.match(buffer: "xxx"))
        try? FileManager.default.removeItem(at: tmp)
    }

    func testMatcherCaseInsensitive() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("snipkey-test-\(UUID().uuidString).json")
        let store = Store(fileURL: tmp)
        store.groups = [SnippetGroup(name: "G", snippets: [
            Snippet(abbreviation: ";Sig", content: "signature", caseSensitive: false),
        ])]
        XCTAssertEqual(store.matcher.match(buffer: "a;sig")?.content, "signature")
        XCTAssertEqual(store.matcher.match(buffer: "a;SIG")?.content, "signature")
        try? FileManager.default.removeItem(at: tmp)
    }

    func testStoreRoundTrip() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("snipkey-test-\(UUID().uuidString).json")
        let store = Store(fileURL: tmp)
        store.groups = [SnipKeyKit.Store.starterGroup(email: "a@b.c")]
        store.macros = [HotkeyMacro(name: "Test", keyCode: 1, modifiers: 256, kind: .openURL, argument: "https://x.y")]
        store.saveNow()

        let reloaded = Store(fileURL: tmp)
        XCTAssertEqual(reloaded.groups.count, 1)
        XCTAssertEqual(reloaded.groups[0].name, "Getting Started")
        XCTAssertEqual(reloaded.macros.count, 1)
        XCTAssertEqual(reloaded.macros[0].kind, .openURL)
        try? FileManager.default.removeItem(at: tmp)
    }
}
