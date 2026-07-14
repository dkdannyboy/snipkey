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
        // 이 테스트가 검증하려는 것은 "가장 긴 접미사가 이긴다"이고,
        // 앞의 'xx'는 원래 의미 없는 패딩이었다. 하지만 패딩이 하필 단어 문자라
        // 단어 경계 규칙 도입 후에는 확장이 정당하게 거부된다. 의도를 유지하려면
        // 약어 앞에 경계를 둬야 한다. (이전 버전은 'xxadd' -> "short"를 기대했는데,
        // 그건 곧 'add'라는 단어 안의 'dd'가 터지는 버그 동작이었다.)
        //
        // 'ddd'/'dd'는 맨몸 약어(단어 문자로 시작)라 종결자가 있어야 발화한다.
        // 종결자가 없으면 사용자가 'dddd…'라는 더 긴 단어를 치는 중일 수 있다.
        // 그래서 버퍼 끝에 스페이스를 붙였다. 검증 의도(최장 우선)는 그대로다.
        let longMatch = store.matcher.match(buffer: "xx ddd ")
        XCTAssertEqual(longMatch?.snippet.content, "long")
        XCTAssertEqual(longMatch?.backspaces, 4)   // 'ddd' + 종결자
        XCTAssertEqual(longMatch?.terminator, " ")

        let shortMatch = store.matcher.match(buffer: "xx dd ")
        XCTAssertEqual(shortMatch?.snippet.content, "short")
        XCTAssertEqual(shortMatch?.backspaces, 3)  // 'dd' + 종결자
        XCTAssertEqual(shortMatch?.terminator, " ")

        XCTAssertNil(store.matcher.match(buffer: "xxx"))

        // 종결자가 없으면 발화하지 않는다 — 접두 모호성 규칙.
        XCTAssertNil(store.matcher.match(buffer: "xx ddd"))
        XCTAssertNil(store.matcher.match(buffer: "xx dd"))

        // 단어 한가운데의 약어는 확장되지 않는다 — 위 회귀의 본체.
        XCTAssertNil(store.matcher.match(buffer: "xxadd"))
        XCTAssertNil(store.matcher.match(buffer: "xxddd"))
        XCTAssertNil(store.matcher.match(buffer: "xxadd "))
        XCTAssertNil(store.matcher.match(buffer: "xxddd "))
        try? FileManager.default.removeItem(at: tmp)
    }

    func testMatcherCaseInsensitive() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("snipkey-test-\(UUID().uuidString).json")
        let store = Store(fileURL: tmp)
        store.groups = [SnippetGroup(name: "G", snippets: [
            Snippet(abbreviation: ";Sig", content: "signature", caseSensitive: false),
        ])]
        XCTAssertEqual(store.matcher.match(buffer: "a;sig")?.snippet.content, "signature")
        XCTAssertEqual(store.matcher.match(buffer: "a;SIG")?.snippet.content, "signature")
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
        XCTAssertEqual(store.matcher.match(buffer: "a;r")?.snippet.content, "rescued")

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

    // MARK: - Import must not claim success it did not achieve

    /// Importing into an unreadable store must fail loudly, not report a count
    /// for snippets that only ever existed in memory.
    func testImportIsRefusedWhileStoreIsUnreadable() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("snipkey-import-blocked-\(UUID().uuidString).json")
        let corrupt = Data("{ not json".utf8)
        try corrupt.write(to: tmp)

        let store = Store(fileURL: tmp)
        XCTAssertTrue(store.isReadOnlyUntilRecovered)

        let outcome = store.importGroups([
            SnippetGroup(name: "Imported", snippets: [Snippet(abbreviation: ";i", content: "x")]),
        ])
        XCTAssertEqual(outcome, .blockedByLoadFailure)
        XCTAssertFalse(outcome.didSave)
        XCTAssertTrue(store.groups.isEmpty, "import must not mutate the library it cannot save")
        XCTAssertEqual(try Data(contentsOf: tmp), corrupt)

        try? FileManager.default.removeItem(at: tmp)
        if let backup = store.loadFailure?.backupURL {
            try? FileManager.default.removeItem(at: backup)
        }
    }

    func testImportReportsSavedWhenItReachesDisk() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("snipkey-import-ok-\(UUID().uuidString).json")
        let store = Store(fileURL: tmp)

        let outcome = store.importGroups([
            SnippetGroup(name: "Imported", snippets: [Snippet(abbreviation: ";i", content: "x")]),
        ])
        XCTAssertEqual(outcome, .saved)

        let reloaded = Store(fileURL: tmp)
        XCTAssertEqual(reloaded.groups.map(\.name), ["Imported"])

        try? FileManager.default.removeItem(at: tmp)
    }

    /// After recovery, importing works again and actually persists.
    func testImportWorksAfterStartingFresh() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("snipkey-import-recover-\(UUID().uuidString).json")
        try Data("{ broken".utf8).write(to: tmp)

        let store = Store(fileURL: tmp)
        XCTAssertEqual(store.importGroups([SnippetGroup(name: "A")]), .blockedByLoadFailure)

        store.startFreshDiscardingUnreadableStore()
        XCTAssertEqual(store.importGroups([SnippetGroup(name: "A")]), .saved)
        XCTAssertEqual(Store(fileURL: tmp).groups.map(\.name), ["A"])

        try? FileManager.default.removeItem(at: tmp)
        if let backup = store.loadFailure?.backupURL {
            try? FileManager.default.removeItem(at: backup)
        }
    }

    /// A save must encode a snapshot taken at mutation time, so edits that land
    /// while a write is in flight cannot corrupt what gets written.
    func testConcurrentEditsDuringSaveDoNotCorruptTheFile() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("snipkey-race-\(UUID().uuidString).json")
        let store = Store(fileURL: tmp)

        for i in 0..<200 {
            store.groups = [SnippetGroup(name: "G\(i)", snippets: [
                Snippet(abbreviation: ";\(i)", content: "v\(i)"),
            ])]
            _ = store.saveNow()
        }

        // Whatever landed must be complete, decodable JSON — never a torn write.
        let reloaded = Store(fileURL: tmp)
        XCTAssertNil(reloaded.loadFailure)
        XCTAssertEqual(reloaded.groups.count, 1)
        XCTAssertEqual(reloaded.groups[0].name, "G199")

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
