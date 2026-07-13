import XCTest
@testable import SnipKeyKit

final class SnippetSearchTests: XCTestCase {

    private func makeGroups() -> [SnippetGroup] {
        [
            SnippetGroup(name: "Email", snippets: [
                Snippet(abbreviation: ";sig", content: "Best regards,\nDaniel", label: "Signature"),
                Snippet(abbreviation: ";sigfull", content: "Long signature block", label: "Full signature"),
                Snippet(abbreviation: ";thx", content: "Thanks for signing up!", label: "Thanks"),
            ]),
            SnippetGroup(name: "Work", snippets: [
                Snippet(abbreviation: "~addr", content: "1 Infinite Loop", label: "Office address"),
            ]),
        ]
    }

    func testExactAbbreviationRanksFirst() {
        let hits = SnippetSearch.run(query: ";sig", in: makeGroups())
        XCTAssertEqual(hits.first?.snippet.abbreviation, ";sig")
        // The prefix match is still found, just ranked lower.
        XCTAssertTrue(hits.contains { $0.snippet.abbreviation == ";sigfull" })
    }

    func testSearchesLabel() {
        let hits = SnippetSearch.run(query: "office", in: makeGroups())
        XCTAssertEqual(hits.map(\.snippet.abbreviation), ["~addr"])
    }

    func testSearchesContent() {
        // "signing" only appears in content, and only in ;thx.
        let hits = SnippetSearch.run(query: "signing up", in: makeGroups())
        XCTAssertEqual(hits.map(\.snippet.abbreviation), [";thx"])
    }

    func testAbbreviationBeatsContentMatch() {
        // ";sig" matches ;sig/;sigfull by abbreviation and ;thx by content
        // ("signing"). Abbreviation matches must come first.
        let hits = SnippetSearch.run(query: "sig", in: makeGroups())
        XCTAssertEqual(hits.first?.snippet.abbreviation, ";sig")
        XCTAssertEqual(hits.last?.snippet.abbreviation, ";thx")
    }

    func testResultsCarryTheirGroup() {
        let hits = SnippetSearch.run(query: "addr", in: makeGroups())
        XCTAssertEqual(hits.first?.groupName, "Work")
    }

    func testCaseInsensitive() {
        XCTAssertEqual(
            SnippetSearch.run(query: "SIGNATURE", in: makeGroups()).first?.snippet.abbreviation,
            ";sig"
        )
    }

    func testEmptyQueryReturnsNothing() {
        XCTAssertTrue(SnippetSearch.run(query: "   ", in: makeGroups()).isEmpty)
    }

    func testLimit() {
        XCTAssertEqual(SnippetSearch.run(query: "s", in: makeGroups(), limit: 2).count, 2)
    }

    func testDisabledCanBeExcluded() {
        var groups = makeGroups()
        groups[0].snippets[0].enabled = false
        let hits = SnippetSearch.run(query: ";sig", in: groups, includeDisabled: false)
        XCTAssertFalse(hits.contains { $0.snippet.abbreviation == ";sig" })
    }

    // MARK: - Conflicts

    func testConflictingAbbreviationsAreDetected() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("snipkey-conflict-\(UUID().uuidString).json")
        let store = Store(fileURL: tmp)
        store.groups = [
            SnippetGroup(name: "A", snippets: [Snippet(abbreviation: ";dup", content: "one")]),
            SnippetGroup(name: "B", snippets: [Snippet(abbreviation: ";dup", content: "two")]),
        ]
        XCTAssertEqual(store.conflictingAbbreviations(), [";dup"])

        let first = store.groups[0].snippets[0]
        let others = store.snippetsClaiming(abbreviation: ";dup", excluding: first.id)
        XCTAssertEqual(others.map(\.groupName), ["B"])

        try? FileManager.default.removeItem(at: tmp)
    }

    func testNoFalseConflictAcrossDisabledSnippets() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("snipkey-conflict2-\(UUID().uuidString).json")
        let store = Store(fileURL: tmp)
        store.groups = [
            SnippetGroup(name: "A", snippets: [Snippet(abbreviation: ";dup", content: "one")]),
            SnippetGroup(name: "B", snippets: [
                Snippet(abbreviation: ";dup", content: "two", enabled: false),
            ]),
        ]
        XCTAssertTrue(store.conflictingAbbreviations().isEmpty)
        try? FileManager.default.removeItem(at: tmp)
    }

    // MARK: - Settings migration

    /// Stores written before the inline-search settings existed must still load.
    func testOlderSettingsDecodeWithDefaults() throws {
        let json = """
        {"expansionEnabled":true,"playSoundOnExpand":false,"didFinishOnboarding":true,"clipboardRestoreDelay":0.4}
        """
        let settings = try JSONDecoder.snipKey.decode(AppSettings.self, from: Data(json.utf8))
        XCTAssertFalse(settings.playSoundOnExpand)
        XCTAssertTrue(settings.inlineSearchEnabled)
        XCTAssertEqual(settings.inlineSearchKeyCode, 44)  // slash
        XCTAssertEqual(settings.inlineSearchModifiers, 256) // command
    }
}
