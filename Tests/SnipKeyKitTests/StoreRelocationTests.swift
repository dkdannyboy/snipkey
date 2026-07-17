import XCTest
@testable import SnipKeyKit

/// M4 위치 전환과 REQ-WRITE-005 원격 변경 해소. 파일 선택 모달(NSOpenPanel/NSSavePanel)은
/// 자동화 불가라 UI가 담당하고, 그 아래 로직은 이미 고른 URL을 받는 Store 메서드로
/// 내려 여기서 직접 검증한다. 백업이 실제 홈 디렉터리를 더럽히지 않도록 지원 디렉터리를
/// 임시 경로로 주입한다.
final class StoreRelocationTests: XCTestCase {

    private var suiteNames: [String] = []
    private var scratchDirs: [URL] = []

    override func tearDown() {
        for name in suiteNames { UserDefaults.standard.removePersistentDomain(forName: name) }
        suiteNames = []
        for dir in scratchDirs { try? FileManager.default.removeItem(at: dir) }
        scratchDirs = []
        super.tearDown()
    }

    private func makeDefaults() -> UserDefaults {
        let name = "snipkey-reloc-\(UUID().uuidString)"
        suiteNames.append(name)
        guard let d = UserDefaults(suiteName: name) else { fatalError("suite \(name) failed") }
        return d
    }

    private func makeDir(_ tag: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("snipkey-\(tag)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        scratchDirs.append(dir)
        return dir
    }

    private func library(_ name: String, count: Int) -> [SnippetGroup] {
        [SnippetGroup(name: name, snippets: (0..<count).map {
            Snippet(abbreviation: ";s\($0)", content: "c\($0)")
        })]
    }

    private func write(_ data: StoreData, to url: URL) throws {
        try JSONEncoder.snipKey.encode(data).write(to: url)
    }

    private func read(_ url: URL) throws -> StoreData {
        try JSONDecoder.snipKey.decode(StoreData.self, from: Data(contentsOf: url))
    }

    private func snippetCount(_ url: URL) throws -> Int {
        try read(url).groups.flatMap(\.snippets).count
    }

    private func drainMainQueueAndDebounce() {
        let drained = expectation(description: "main queue drained")
        DispatchQueue.main.async { drained.fulfill() }
        wait(for: [drained], timeout: 2)
        Thread.sleep(forTimeInterval: 0.8)
    }

    // MARK: - AC-CORE-007 블록 1 — "Save Snippets As…"

    /// 첫 Mac. 331개를 동기화 폴더로 복사하고, 기존 로컬 파일은 그대로 둔다.
    func testSaveSnippetsAsCopiesLibraryAndLeavesLocalFileIntact() throws {
        let localDir = try makeDir("local")
        let localFile = localDir.appendingPathComponent("store.json")
        try write(StoreData(groups: library("Big", count: 331)), to: localFile)

        let defaults = makeDefaults()
        let store = Store(
            location: Store.Location(fileURL: localFile, expectsExistingLibrary: false),
            deviceDefaults: defaults,
            localSupportDirectory: localDir
        )
        XCTAssertEqual(store.allSnippets.count, 331)

        let syncDir = try makeDir("sync")
        let result = store.saveSnippetsAs(toDirectory: syncDir)
        XCTAssertTrue(result.success)

        let syncFile = syncDir.appendingPathComponent(Store.syncedFileName)
        XCTAssertEqual(try snippetCount(syncFile), 331, "동기화 폴더의 새 파일에 331개가 모두 있어야 한다")
        XCTAssertTrue(FileManager.default.fileExists(atPath: localFile.path))
        XCTAssertEqual(try snippetCount(localFile), 331, "기존 로컬 파일이 그대로 남아 있어야 한다 (REQ-LOC-008)")

        XCTAssertEqual(defaults.string(forKey: Store.DeviceStateKey.storeLocationPath), syncFile.path)
        XCTAssertEqual(store.activeLocationURL.path, syncFile.path, "재시작 없이 새 위치가 활성이어야 한다")
        XCTAssertEqual(store.allSnippets.count, 331)
        XCTAssertTrue(store.isUsingConfiguredLocation)
    }

    // MARK: - AC-CORE-007 블록 2 — "Link to Snippets…"

    /// 두 번째 Mac. 로컬 5개를 백업하고, 331개 파일을 채택하되 그 파일을 절대 덮지
    /// 않는다. 그리고 온보딩 완료 플래그를 지운다 (M4 의무).
    func testLinkToSnippetsBacksUpLocalNeverOverwritesTargetAndResetsOnboarding() throws {
        let localDir = try makeDir("local")
        let localFile = localDir.appendingPathComponent("store.json")
        try write(StoreData(groups: library("Local", count: 5)), to: localFile)

        let defaults = makeDefaults()
        let store = Store(
            location: Store.Location(fileURL: localFile, expectsExistingLibrary: false),
            deviceDefaults: defaults,
            localSupportDirectory: localDir
        )
        XCTAssertEqual(store.allSnippets.count, 5)
        store.didFinishOnboarding = true // 이 Mac에서는 이미 온보딩을 마쳤다고 가정

        let syncDir = try makeDir("sync")
        let syncFile = syncDir.appendingPathComponent("shared.json")
        try write(StoreData(groups: library("Shared", count: 331)), to: syncFile)

        let result = store.linkToSnippets(at: syncFile)
        XCTAssertTrue(result.success)

        // 가드 #8 — 대상 파일이 5개로 덮이면 안 된다 (최악의 경로).
        XCTAssertEqual(try snippetCount(syncFile), 331, "링크 대상이 로컬 라이브러리로 덮이면 안 된다")

        // 가드 #7 — 로컬 5개가 타임스탬프 백업으로 회수 가능해야 한다.
        let backup = try XCTUnwrap(result.backupURL, "로컬 라이브러리 백업이 있어야 한다")
        XCTAssertEqual(try snippetCount(backup), 5, "백업에 로컬 5개가 담겨야 한다")
        XCTAssertNotNil(result.message, "백업 경로가 사용자에게 표시돼야 한다")

        // M4 의무 — 온보딩 플래그가 지워져야 두 번째 Mac에서 온보딩이 다시 뜬다.
        XCTAssertFalse(store.didFinishOnboarding)
        XCTAssertEqual(defaults.object(forKey: Store.DeviceStateKey.didFinishOnboarding) as? Bool, false)

        XCTAssertEqual(store.allSnippets.count, 331)
        XCTAssertEqual(defaults.string(forKey: Store.DeviceStateKey.storeLocationPath), syncFile.path)
    }

    /// 두 번째 Mac 재실행 시뮬레이션: 링크가 온보딩 플래그를 false로 못 박았으므로,
    /// 다음 실행이 파일의 didFinishOnboarding:true를 시드 분기로 덮어쓰지 않는다.
    func testAfterLinkNextLaunchDoesNotSuppressOnboardingFromFileValue() throws {
        let localDir = try makeDir("local")
        let localFile = localDir.appendingPathComponent("store.json")
        try write(StoreData(groups: library("Local", count: 5)), to: localFile)

        let defaults = makeDefaults()
        let store = Store(
            location: Store.Location(fileURL: localFile, expectsExistingLibrary: false),
            deviceDefaults: defaults, localSupportDirectory: localDir
        )

        let syncDir = try makeDir("sync")
        let syncFile = syncDir.appendingPathComponent("shared.json")
        var onboardedSettings = AppSettings()
        onboardedSettings.didFinishOnboarding = true // Mac A가 온보딩을 마친 파일
        try write(StoreData(groups: library("Shared", count: 331), settings: onboardedSettings), to: syncFile)

        _ = store.linkToSnippets(at: syncFile)

        // 다음 실행: 같은 UserDefaults suite로 새 Store를 만든다.
        let relaunched = Store(
            location: Store.resolveLocation(environment: [:], defaults: defaults),
            deviceDefaults: defaults, localSupportDirectory: localDir
        )
        XCTAssertFalse(
            relaunched.didFinishOnboarding,
            "링크가 플래그를 false로 못 박았으므로 파일의 true가 온보딩을 억제하면 안 된다"
        )
    }

    // MARK: - AC-CORE-007 블록 3 — "Don't Sync"

    /// 로컬 기본 경로로 현재 라이브러리를 복사하고, 동기화 파일은 그대로 둔다.
    func testStopSyncingCopiesToLocalDefaultAndLeavesSyncedFile() throws {
        let localDir = try makeDir("local")
        let syncDir = try makeDir("sync")
        let syncFile = syncDir.appendingPathComponent("shared.json")
        try write(StoreData(groups: library("Shared", count: 331)), to: syncFile)

        let defaults = makeDefaults()
        defaults.set(syncFile.path, forKey: Store.DeviceStateKey.storeLocationPath)

        let store = Store(
            location: Store.resolveLocation(environment: [:], defaults: defaults),
            deviceDefaults: defaults, localSupportDirectory: localDir
        )
        XCTAssertEqual(store.allSnippets.count, 331)
        XCTAssertTrue(store.isUsingConfiguredLocation)

        let result = store.stopSyncing()
        XCTAssertTrue(result.success)

        let localDefault = localDir.appendingPathComponent("store.json")
        XCTAssertEqual(try snippetCount(localDefault), 331, "로컬 기본 경로에 현재 라이브러리 전체가 복사돼야 한다")
        XCTAssertTrue(FileManager.default.fileExists(atPath: syncFile.path))
        XCTAssertEqual(try snippetCount(syncFile), 331, "동기화 폴더의 파일이 그대로 남아 있어야 한다")

        XCTAssertNil(defaults.string(forKey: Store.DeviceStateKey.storeLocationPath), "포인터가 지워져야 한다")
        XCTAssertFalse(store.isUsingConfiguredLocation)
        XCTAssertEqual(store.activeLocationURL.path, localDefault.path)
    }

    // MARK: - AC-SIDE-008 — 실행 중 재배치

    /// Store를 새로 만들지 않고 제자리에서 위치를 바꾼다. 대기 중 저장은 결정적으로
    /// 버려지고(옛 경로도, 새 대상도 덮지 않는다), matcher가 재구축되며, 재시작이 없다.
    func testRelocateHandlesPendingSaveRebuildsMatcherWithoutRestart() throws {
        let dirA = try makeDir("A")
        let fileA = dirA.appendingPathComponent("store.json")
        try write(StoreData(groups: [SnippetGroup(name: "A", snippets: [Snippet(abbreviation: ";a", content: "AAA")])]), to: fileA)

        let dirB = try makeDir("B")
        let fileB = dirB.appendingPathComponent("other.json")
        try write(StoreData(groups: [SnippetGroup(name: "B", snippets: [Snippet(abbreviation: ";b", content: "BBB")])]), to: fileB)

        let store = Store(fileURL: fileA, deviceDefaults: makeDefaults())
        XCTAssertEqual(store.matcher.match(buffer: ";a")?.snippet.content, "AAA")

        // 대기 중 디바운스 저장을 만든다.
        store.groups[0].snippets[0].content = "대기 중 편집"

        store.relocate(to: Store.Location(fileURL: fileB, expectsExistingLibrary: true))

        // matcher가 새 라이브러리로 재구축됐다.
        XCTAssertNil(store.matcher.match(buffer: ";a"), "옛 라이브러리의 약어는 더 이상 매치되면 안 된다")
        XCTAssertEqual(store.matcher.match(buffer: ";b")?.snippet.content, "BBB")
        XCTAssertEqual(store.groups.map(\.name), ["B"])

        // 대기 중 저장이 버려졌다 — 옛 경로도, 새 대상도 우리 것으로 덮이지 않았다.
        drainMainQueueAndDebounce()
        XCTAssertEqual(try read(fileA).groups[0].snippets[0].content, "AAA", "옛 경로로의 대기 저장은 버려져야 한다")
        XCTAssertEqual(try read(fileB).groups[0].snippets[0].content, "BBB", "재배치가 대상 파일을 우리 것으로 덮으면 안 된다")

        // 새 위치에서 저장이 정상 동작한다 (재시작 불필요).
        XCTAssertEqual(store.saveNow(), .saved)
    }

    // MARK: - REQ-WRITE-005 — 원격 변경 해소 3종 (양쪽 다 회수 가능)

    /// dirty + 원격 변경으로 막힌 store를 만든다. 반환된 store는 blockedByRemoteChange
    /// 상태이고 remoteChange가 published돼 있다.
    private func makeConflictedStore(
        file: URL, supportDir: URL, defaults: UserDefaults
    ) throws -> Store {
        try write(StoreData(groups: [SnippetGroup(name: "Shared", snippets: [Snippet(abbreviation: ";one", content: "1")])]), to: file)
        let store = Store(
            location: Store.Location(fileURL: file, expectsExistingLibrary: false),
            deviceDefaults: defaults, localSupportDirectory: supportDir
        )
        // 로컬 편집(dirty).
        store.groups[0].snippets[0].content = "내 편집"
        // 다른 Mac이 파일을 갈아치웠다.
        try write(StoreData(groups: [SnippetGroup(name: "Shared", snippets: [
            Snippet(abbreviation: ";one", content: "1"),
            Snippet(abbreviation: ";two", content: "2"),
        ])]), to: file)
        store.externalChangeDetected()
        XCTAssertEqual(store.saveNow(), .blockedByRemoteChange)
        XCTAssertNotNil(store.remoteChange, "원격 변경이 UI에 표면화돼야 한다 (REQ-WRITE-004)")
        return store
    }

    func testResolveByTakingRemoteBacksUpLocalEditsAndAdoptsTheirs() throws {
        let dir = try makeDir("conf")
        let file = dir.appendingPathComponent("store.json")
        let defaults = makeDefaults()
        let store = try makeConflictedStore(file: file, supportDir: dir, defaults: defaults)

        let res = store.resolveByTakingRemote()
        let backup = try XCTUnwrap(res.backupURL, "로컬 편집이 백업으로 회수 가능해야 한다")
        XCTAssertEqual(try read(backup).groups[0].snippets[0].content, "내 편집")

        // 인메모리가 theirs를 채택했고, 저장이 다시 풀렸다.
        XCTAssertEqual(store.groups[0].snippets.map(\.abbreviation), [";one", ";two"])
        XCTAssertNil(store.remoteChange)
        XCTAssertEqual(store.saveNow(), .saved)
    }

    func testResolveByKeepingLocalBacksUpTheirsAndForceWritesMine() throws {
        let dir = try makeDir("conf")
        let file = dir.appendingPathComponent("store.json")
        let defaults = makeDefaults()
        let store = try makeConflictedStore(file: file, supportDir: dir, defaults: defaults)

        let res = store.resolveByKeepingLocal()
        XCTAssertEqual(res.outcome, .saved)
        let backup = try XCTUnwrap(res.backupURL, "그쪽 버전이 백업으로 회수 가능해야 한다")
        XCTAssertEqual(try read(backup).groups[0].snippets.map(\.abbreviation), [";one", ";two"], "백업은 그쪽 버전이어야 한다")

        // 디스크는 이제 내 것.
        XCTAssertEqual(try read(file).groups[0].snippets[0].content, "내 편집")
        XCTAssertNil(store.remoteChange)
    }

    func testResolveByKeepingBothWritesMineToSiblingAndReloadsTheirs() throws {
        let dir = try makeDir("conf")
        let file = dir.appendingPathComponent("store.json")
        let defaults = makeDefaults()
        let store = try makeConflictedStore(file: file, supportDir: dir, defaults: defaults)

        let res = store.resolveByKeepingBoth()
        let sibling = try XCTUnwrap(res.backupURL, "내 것이 형제 파일로 회수 가능해야 한다")
        XCTAssertEqual(try read(sibling).groups[0].snippets[0].content, "내 편집")

        // 대상 파일은 그쪽 것 그대로, 인메모리도 그쪽 것을 리로드.
        XCTAssertEqual(try read(file).groups[0].snippets.map(\.abbreviation), [";one", ";two"])
        XCTAssertEqual(store.groups[0].snippets.map(\.abbreviation), [";one", ";two"])
        XCTAssertNil(store.remoteChange)
    }
}
