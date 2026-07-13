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

    // MARK: - Corrupt store recovery

    /// A store file that exists but cannot be decoded must never be silently
    /// replaced with an empty library.
    func testCorruptStoreIsNotOverwritten() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("snipkey-corrupt-\(UUID().uuidString).json")
        let corrupt = Data("{ this is not valid json".utf8)
        try corrupt.write(to: tmp)

        let store = Store(fileURL: tmp)
        XCTAssertNotNil(store.loadFailure)
        XCTAssertTrue(store.groups.isEmpty)

        // Any mutation would normally trigger a save. It must not touch the file.
        store.groups.append(SnippetGroup(name: "Should not persist"))
        store.saveNow()

        let onDisk = try Data(contentsOf: tmp)
        XCTAssertEqual(onDisk, corrupt, "the unreadable store was overwritten")

        try? FileManager.default.removeItem(at: tmp)
        if let backup = store.loadFailure?.backupURL {
            XCTAssertEqual(try? Data(contentsOf: backup), corrupt)
            try? FileManager.default.removeItem(at: backup)
        }
    }

    func testCorruptStoreIsBackedUp() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("snipkey-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("store.json")
        try Data("garbage".utf8).write(to: file)

        let store = Store(fileURL: file)
        let backup = try XCTUnwrap(store.loadFailure?.backupURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: backup.path))
        XCTAssertEqual(try Data(contentsOf: backup), Data("garbage".utf8))

        try? FileManager.default.removeItem(at: dir)
    }

    /// Explicitly starting fresh is the one path that may replace the file.
    func testStartFreshDiscardsCorruptStore() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("snipkey-fresh-\(UUID().uuidString).json")
        try Data("{ broken".utf8).write(to: tmp)

        let store = Store(fileURL: tmp)
        XCTAssertNotNil(store.loadFailure)

        store.startFreshDiscardingUnreadableStore()
        XCTAssertNil(store.loadFailure)

        store.groups = [SnippetGroup(name: "New", snippets: [Snippet(abbreviation: ";x", content: "y")])]
        store.saveNow()

        let reloaded = Store(fileURL: tmp)
        XCTAssertNil(reloaded.loadFailure)
        XCTAssertEqual(reloaded.groups.map(\.name), ["New"])

        try? FileManager.default.removeItem(at: tmp)
        if let backup = store.loadFailure?.backupURL {
            try? FileManager.default.removeItem(at: backup)
        }
    }

    /// Repairing the file by hand and retrying must restore the real library.
    func testRetryLoadingStoreAfterRepair() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("snipkey-retry-\(UUID().uuidString).json")
        try Data("{ broken".utf8).write(to: tmp)

        let store = Store(fileURL: tmp)
        XCTAssertNotNil(store.loadFailure)
        XCTAssertFalse(store.retryLoadingStore(), "still broken — retry must fail")

        // The user repairs the file.
        let good = StoreData(groups: [SnippetGroup(name: "Rescued", snippets: [
            Snippet(abbreviation: ";r", content: "rescued"),
        ])])
        try JSONEncoder.snipKey.encode(good).write(to: tmp)

        XCTAssertTrue(store.retryLoadingStore())
        XCTAssertNil(store.loadFailure)
        XCTAssertEqual(store.groups.map(\.name), ["Rescued"])
        XCTAssertEqual(store.matcher.match(buffer: "a;r")?.content, "rescued")

        try? FileManager.default.removeItem(at: tmp)
    }

    /// A missing file is a first launch, not a failure.
    func testMissingStoreIsNotAFailure() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("snipkey-missing-\(UUID().uuidString).json")
        let store = Store(fileURL: tmp)
        XCTAssertNil(store.loadFailure)

        store.groups = [Store.starterGroup()]
        store.saveNow()
        XCTAssertTrue(FileManager.default.fileExists(atPath: tmp.path))

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
