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
    /// 않는다. 그리고 이미 이 Mac에서 마친 온보딩 플래그는 **건드리지 않는다**.
    /// (사용자 버그 재현: 이미 온보딩을 마친 주 Mac에서 링크하면 온보딩이 다시 뜬다.)
    func testLinkToSnippetsBacksUpLocalNeverOverwritesTargetAndKeepsOnboardingState() throws {
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

        // 핵심 불변식 — 링크는 온보딩 플래그를 건드리면 안 된다. didFinishOnboarding은
        // 장치-로컬(이 Mac이 접근성을 스스로 승인했는가)이라, 이미 설정을 마친 Mac이
        // 공유 라이브러리를 채택했다고 온보딩을 다시 띄우면 안 된다. 새 Mac은 자기
        // 장치 키가 false라 어차피 온보딩이 뜨므로, 여기서 false로 못 박을 이유가 없고,
        // 못 박으면 이미 셋업된 Mac까지 재-온보딩된다(사용자가 겪은 버그).
        XCTAssertTrue(store.didFinishOnboarding, "이미 온보딩을 마친 Mac은 링크 후에도 온보딩 상태를 유지해야 한다")
        XCTAssertEqual(defaults.object(forKey: Store.DeviceStateKey.didFinishOnboarding) as? Bool, true)

        XCTAssertEqual(store.allSnippets.count, 331)
        XCTAssertEqual(defaults.string(forKey: Store.DeviceStateKey.storeLocationPath), syncFile.path)
    }

    /// 온보딩 시드의 위치 인식 — 이 버그의 핵심인 두 방향을 한자리에서 못 박는다.
    ///
    /// 방향 1 (동기화 파일은 시드하지 않는다): 아직 자기 접근성을 승인 안 한 Mac(장치 키
    /// 부재)이 didFinishOnboarding:true인 **동기화 파일**을 가리키면, 그 파일 값은 장치
    /// 플래그를 시드하지 않는다 — 온보딩이 떠야 한다. (동기화 파일이 새 Mac의 온보딩을
    /// 억제하던 문제. 이제 링크가 플래그를 false로 못 박지 않으므로, 억제 차단은 오직
    /// 위치 인식 시드가 담당한다.)
    ///
    /// 방향 2 (로컬 기본은 시드한다): 자기 **로컬 기본** store.json에 true가 있고 장치
    /// 키가 부재인 Mac은 시드된다 — pre-장치-로컬 빌드에서 업그레이드한 기존 사용자가
    /// 온보딩을 다시 보지 않게 하는 승계.
    func testOnboardingSeedIsLocalDefaultOnlyNotSyncedFile() throws {
        // 방향 1 — 동기화 파일은 온보딩을 억제하지 않는다. 갓 셋업하는 Mac은 아직
        // 로컬 store.json이 없고(장치 키 부재), 자기 접근성도 승인 안 했다. 그 Mac이
        // didFinishOnboarding:true인 **동기화 파일**을 가리켜도 온보딩이 떠야 한다.
        // (로컬 파일을 두면 그 파일의 기본 false가 장치 키를 미리 못 박아 시드 분기를
        // 가리므로, 진짜 첫 실행처럼 로컬 파일 없이 재현한다.)
        let syncDir = try makeDir("sync")
        let syncFile = syncDir.appendingPathComponent("shared.json")
        var onboardedSettings = AppSettings()
        onboardedSettings.didFinishOnboarding = true // Mac A가 온보딩을 마친 파일
        try write(StoreData(groups: library("Shared", count: 331), settings: onboardedSettings), to: syncFile)

        let freshDir = try makeDir("fresh") // 로컬 store.json 없음 = 아직 온보딩 안 한 Mac
        let freshDefaults = makeDefaults()  // 장치 키 부재
        freshDefaults.set(syncFile.path, forKey: Store.DeviceStateKey.storeLocationPath)

        let relaunched = Store(
            location: Store.resolveLocation(environment: [:], defaults: freshDefaults),
            deviceDefaults: freshDefaults, localSupportDirectory: freshDir
        )
        XCTAssertTrue(relaunched.isUsingConfiguredLocation, "동기화 포인터가 활성 위치여야 한다")
        XCTAssertEqual(relaunched.allSnippets.count, 331, "동기화 라이브러리를 채택해야 한다")
        XCTAssertFalse(
            relaunched.didFinishOnboarding,
            "동기화 파일의 true는 아직 접근성을 승인 안 한 Mac의 온보딩을 시드/억제하면 안 된다"
        )

        // 방향 2 — 로컬 기본은 여전히 시드한다(업그레이드 승계).
        let upgradeDir = try makeDir("upgrade")
        let upgradeFile = upgradeDir.appendingPathComponent("store.json")
        var upgradeSettings = AppSettings()
        upgradeSettings.didFinishOnboarding = true
        try write(StoreData(groups: library("Upgrade", count: 3), settings: upgradeSettings), to: upgradeFile)

        let upgradeDefaults = makeDefaults() // 장치 키 부재
        let upgraded = Store(
            location: Store.Location(fileURL: upgradeFile, expectsExistingLibrary: false),
            deviceDefaults: upgradeDefaults, localSupportDirectory: upgradeDir
        )
        XCTAssertTrue(
            upgraded.didFinishOnboarding,
            "로컬 기본 store.json의 true는 시드돼야 한다 — 업그레이드한 기존 사용자가 재-온보딩되면 안 된다"
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

    // MARK: - 커밋-전-검증 구멍 (Codex adversarial review)

    /// 결함 #1 — "Save Snippets As…"가 백업을 못 뜨면 기존 대상을 덮으면 안 된다.
    /// 예전 코드는 백업 성공 여부를 확인하지 않고 곧장 대상을 덮었다. 대상이 이미
    /// 남의 동기화 라이브러리(331개)를 담고 있고 백업이 실패하면, 그 라이브러리가
    /// 로컬 스냅샷으로 회수 불가능하게 파괴됐다. 백업 디렉터리를 쓰기 불가로 만들어
    /// writeBackup을 nil로 되돌린 채, 대상이 그대로 남는지 확인한다.
    func testSaveSnippetsAsRefusesToOverwriteExistingTargetWhenBackupFails() throws {
        try XCTSkipIf(getuid() == 0, "root는 권한을 무시하고 써서 백업 실패를 만들 수 없다")

        let localDir = try makeDir("local")
        let localFile = localDir.appendingPathComponent("store.json")
        try write(StoreData(groups: library("Local", count: 5)), to: localFile)

        // 백업(=지원) 디렉터리를 쓰기 불가로 만든다 → writeBackup이 nil을 돌려준다.
        let supportDir = try makeDir("support")

        let defaults = makeDefaults()
        let store = Store(
            location: Store.Location(fileURL: localFile, expectsExistingLibrary: false),
            deviceDefaults: defaults,
            localSupportDirectory: supportDir
        )
        XCTAssertEqual(store.allSnippets.count, 5)

        // 대상 폴더에 이미 331개짜리 동기화 라이브러리가 있다.
        let syncDir = try makeDir("sync")
        let target = syncDir.appendingPathComponent(Store.syncedFileName)
        try write(StoreData(groups: library("Existing", count: 331)), to: target)

        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: supportDir.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: supportDir.path) }

        let result = store.saveSnippetsAs(toDirectory: syncDir)

        XCTAssertFalse(result.success, "백업을 못 뜨면 기존 대상을 덮지 말고 실패해야 한다")
        XCTAssertEqual(try snippetCount(target), 331, "기존 동기화 라이브러리가 로컬 5개로 덮이면 안 된다")
        XCTAssertNil(
            defaults.string(forKey: Store.DeviceStateKey.storeLocationPath),
            "실패 시 포인터를 옮기면 안 된다"
        )
        XCTAssertEqual(store.activeLocationURL.path, localFile.path, "실패 시 활성 위치가 그대로여야 한다")
    }

    /// 결함 #2 — "Don't Sync"가 로컬 사본을 못 쓰면 성공을 보고하면 안 된다.
    /// 예전 코드는 로컬 쓰기를 `try?`로 무시하고 곧장 포인터를 지운 뒤 빈 로컬
    /// 기본(expectsExistingLibrary:false → 파일 부재 = 빈 첫 실행)을 가리키면서
    /// "동기화를 껐다"고 거짓 보고했다. 로컬 디렉터리를 쓰기 불가로 만들어 포인터가
    /// 동기화 경로에 그대로 남는지 확인한다.
    func testStopSyncingKeepsSyncedPointerWhenLocalWriteFails() throws {
        try XCTSkipIf(getuid() == 0, "root는 쓰기 권한을 무시해 로컬 쓰기 실패를 만들 수 없다")

        let syncDir = try makeDir("sync")
        let syncFile = syncDir.appendingPathComponent("shared.json")
        try write(StoreData(groups: library("Shared", count: 331)), to: syncFile)

        // 로컬 기본/백업 디렉터리를 쓰기 불가로 만들어 로컬 사본 쓰기를 실패시킨다.
        let supportDir = try makeDir("support")

        let defaults = makeDefaults()
        defaults.set(syncFile.path, forKey: Store.DeviceStateKey.storeLocationPath)

        let store = Store(
            location: Store.resolveLocation(environment: [:], defaults: defaults),
            deviceDefaults: defaults, localSupportDirectory: supportDir
        )
        XCTAssertEqual(store.allSnippets.count, 331)
        XCTAssertTrue(store.isUsingConfiguredLocation)

        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: supportDir.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: supportDir.path) }

        let result = store.stopSyncing()

        XCTAssertFalse(result.success, "로컬 사본을 못 쓰면 동기화를 끄지 말고 실패해야 한다")
        XCTAssertEqual(
            defaults.string(forKey: Store.DeviceStateKey.storeLocationPath), syncFile.path,
            "실패 시 포인터가 동기화 경로에 그대로 있어야 한다"
        )
        XCTAssertEqual(store.activeLocationURL.path, syncFile.path, "실패 시 활성 위치가 동기화 파일이어야 한다")
        XCTAssertTrue(store.isUsingConfiguredLocation)
        XCTAssertEqual(store.allSnippets.count, 331, "인메모리 라이브러리도 그대로여야 한다")
    }

    /// 결함 #3 공통 소스: 로컬 5개를 담은, 온보딩을 마친 store.
    private func makeLinkSourceStore() throws -> (store: Store, defaults: UserDefaults, localFile: URL) {
        let localDir = try makeDir("local")
        let localFile = localDir.appendingPathComponent("store.json")
        try write(StoreData(groups: library("Local", count: 5)), to: localFile)
        let defaults = makeDefaults()
        let store = Store(
            location: Store.Location(fileURL: localFile, expectsExistingLibrary: false),
            deviceDefaults: defaults, localSupportDirectory: localDir
        )
        store.didFinishOnboarding = true // 이 Mac에서는 이미 온보딩을 마쳤다.
        XCTAssertEqual(store.allSnippets.count, 5)
        return (store, defaults, localFile)
    }

    /// 결함 #3 공통 검증: 링크가 거부됐고 어떤 상태도 건드리지 않았다.
    private func assertLinkRefused(
        _ result: Store.RelocationResult, store: Store, defaults: UserDefaults, localFile: URL
    ) {
        XCTAssertFalse(result.success, "나쁜 대상에 연결하면 안 된다")
        XCTAssertNotNil(result.message, "실패 이유가 사용자에게 표시돼야 한다")
        XCTAssertNil(
            defaults.string(forKey: Store.DeviceStateKey.storeLocationPath),
            "포인터가 설정되면 안 된다 (검증 전에 커밋 금지)"
        )
        XCTAssertEqual(store.activeLocationURL.path, localFile.path, "활성 위치가 그대로여야 한다")
        XCTAssertTrue(store.didFinishOnboarding, "온보딩 플래그가 유지돼야 한다")
        XCTAssertEqual(store.allSnippets.count, 5, "인메모리 로컬 5개가 그대로여야 한다")
    }

    /// 결함 #3(a) — 깨진 JSON 대상. 예전 코드는 포인터부터 박고 relocate해서 매
    /// 재실행이 깨진 위치를 다시 열었다. 검증을 먼저 하면 아무것도 건드리지 않는다.
    func testLinkRefusesCorruptTargetAndLeavesStateUntouched() throws {
        let (store, defaults, localFile) = try makeLinkSourceStore()

        let syncDir = try makeDir("sync")
        let target = syncDir.appendingPathComponent("shared.json")
        try Data("{ not valid json".utf8).write(to: target)

        let result = store.linkToSnippets(at: target)
        assertLinkRefused(result, store: store, defaults: defaults, localFile: localFile)
    }

    /// 결함 #3(b) — 더 새로운 스키마 대상(version > currentVersion). 채택하면 다음
    /// 저장이 그 필드를 날리는 다운그레이드가 된다. 검증에서 걸러 포인터를 박지 않는다.
    func testLinkRefusesNewerSchemaTargetAndLeavesStateUntouched() throws {
        let (store, defaults, localFile) = try makeLinkSourceStore()

        let syncDir = try makeDir("sync")
        let target = syncDir.appendingPathComponent("shared.json")
        try write(StoreData(version: 99, groups: library("Shared", count: 331)), to: target)

        let result = store.linkToSnippets(at: target)
        assertLinkRefused(result, store: store, defaults: defaults, localFile: localFile)
        XCTAssertEqual(try read(target).version, 99, "신버전 파일은 손대지 않아야 한다")
    }

    /// 결함 #3(c) — 있어야 할 대상이 아직 없다(iCloud 미다운로드/볼륨 없음).
    /// 예전 코드는 부재 위치에 포인터를 박아, 재실행이 빈 라이브러리를 사용자의
    /// 진짜 것인 양 열었다. 검증에서 unavailable을 잡아 포인터를 박지 않는다.
    func testLinkRefusesUnavailableTargetAndLeavesStateUntouched() throws {
        let (store, defaults, localFile) = try makeLinkSourceStore()

        let syncDir = try makeDir("sync")
        let target = syncDir.appendingPathComponent("not-yet-downloaded.json") // 존재하지 않음

        let result = store.linkToSnippets(at: target)
        assertLinkRefused(result, store: store, defaults: defaults, localFile: localFile)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: target.path),
            "부재 대상에 파일을 만들면 안 된다"
        )
    }

    /// 결함 #3 후속 (Codex adversarial review, TOCTOU) — 대상이 검증 시점엔 멀쩡했다가
    /// **실제로 적용되는 로드** 시점에 손상되는 경합. 예전 코드는 preflight 읽기 하나로
    /// 검증하고 곧장 포인터를 박은 뒤, relocate가 두 번째로 읽어 그 결과를 아무도 보지
    /// 않고 적용했다. 그 사이 대상이 삭제·손상·자리표시자화·신버전 교체되면 나쁜 상태를
    /// 채택하고도 커밋+성공했다. 커밋을 "실제로 적용된 로드"에 걸어야 이 창이 사라진다.
    ///
    /// 손상 시점을 **로컬 백업이 떠진 뒤**로 잡는다: 그 신호가 preflight(백업 전)와
    /// 적용 읽기(백업 후)를 가르는 의미 경계이고, 수정이 읽기 횟수를 줄여도 견고하다.
    func testLinkRollsBackWhenTargetGoesBadAtTheAppliedLoad() throws {
        let (store, defaults, localFile) = try makeLinkSourceStore()
        let backupDir = localFile.deletingLastPathComponent() // = 주입된 localSupportDirectory

        let syncDir = try makeDir("sync")
        let target = syncDir.appendingPathComponent("shared.json")
        try write(StoreData(groups: library("Shared", count: 331)), to: target)

        // 로컬 백업이 떠진 뒤 대상 읽기 직전에 대상을 손상시킨다. preflight 읽기는
        // 백업 이전이라 멀쩡한 331개를 보고 통과하지만, 적용 로드는 손상본을 만난다.
        Store._testHookBeforeLoad = { url in
            guard url.path == target.path else { return }
            let backupTaken = (try? FileManager.default.contentsOfDirectory(atPath: backupDir.path))?
                .contains { $0.contains("local-before-link") } ?? false
            if backupTaken { try? Data("{ corrupted mid-flight".utf8).write(to: url) }
        }
        defer { Store._testHookBeforeLoad = nil }

        let result = store.linkToSnippets(at: target)

        // 적용 로드가 나쁘면 전체 롤백 — 아무것도 커밋되지 않는다.
        assertLinkRefused(result, store: store, defaults: defaults, localFile: localFile)
    }
}
