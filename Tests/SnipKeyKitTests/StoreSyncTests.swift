import XCTest
@testable import SnipKeyKit

/// 동기화되는 저장소의 안전장치. `Store`가 `fileURL`을 주입받으므로 두 인스턴스를
/// 하나의 임시 파일에 물리면 그게 곧 두 대의 Mac이다 —
/// `StoreTests.testStoreWritesOnlyToOverriddenPath`가 이미 쓰던 패턴이다.
///
/// 장치-로컬 상태는 UserDefaults에 있으므로, 테스트마다 일회용 suite를 준다.
/// `.standard`를 쓰면 앞 테스트가 심은 값이 뒤 테스트의 시드 분기를 지워 버린다.
final class StoreSyncTests: XCTestCase {

    private var suiteNames: [String] = []
    private var scratchFiles: [URL] = []

    override func tearDown() {
        for name in suiteNames {
            UserDefaults.standard.removePersistentDomain(forName: name)
        }
        suiteNames = []
        for url in scratchFiles {
            try? FileManager.default.removeItem(at: url)
        }
        scratchFiles = []
        super.tearDown()
    }

    private func makeDefaults() -> UserDefaults {
        let name = "snipkey-test-\(UUID().uuidString)"
        suiteNames.append(name)
        // suiteName이 유효하면 절대 nil이 아니다. UUID 기반이므로 유효하다.
        guard let defaults = UserDefaults(suiteName: name) else {
            fatalError("UserDefaults suite \(name) could not be created")
        }
        return defaults
    }

    /// 아직 존재하지 않는 임시 경로.
    private func scratchPath() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("snipkey-sync-\(UUID().uuidString).json")
        scratchFiles.append(url)
        return url
    }

    private func write(_ data: StoreData, to url: URL) throws {
        try JSONEncoder.snipKey.encode(data).write(to: url)
    }

    private func read(_ url: URL) throws -> StoreData {
        try JSONDecoder.snipKey.decode(StoreData.self, from: Data(contentsOf: url))
    }

    /// main 큐에 쌓인 작업을 비우고, 디바운스(0.5s)가 지나도록 기다린다.
    /// 저장이 **일어나지 않음**을 주장하려면 일어날 시간을 실제로 줘야 한다.
    private func drainMainQueueAndDebounce() {
        let drained = expectation(description: "main queue drained")
        DispatchQueue.main.async { drained.fulfill() }
        wait(for: [drained], timeout: 2)
        Thread.sleep(forTimeInterval: 0.8)
    }

    private func library(_ name: String, _ snippets: [Snippet]) -> [SnippetGroup] {
        [SnippetGroup(name: name, snippets: snippets)]
    }

    // MARK: - AC-CORE-001 — 낡은 스냅샷이 새 내용을 덮지 못한다

    /// 이 SPEC의 존재 이유. 두 Mac이 앱을 켜 둔 채 한쪽이 편집하면, 다른 쪽의
    /// 실행 시점 스냅샷이 그 편집을 조용히 지우던 것이 원래 버그다.
    func testStaleSnapshotCannotClobberAnotherMacsEdit() throws {
        let file = scratchPath()
        try write(StoreData(groups: library("Shared", [
            Snippet(abbreviation: ";one", content: "1"),
        ])), to: file)

        let storeA = Store(fileURL: file, deviceDefaults: makeDefaults())
        let storeB = Store(fileURL: file, deviceDefaults: makeDefaults())

        // Mac B가 편집하고 저장한다.
        storeB.groups[0].snippets.append(Snippet(abbreviation: ";two", content: "2"))
        XCTAssertEqual(storeB.saveNow(), .saved)

        // Mac A는 여전히 실행 시점 스냅샷을 들고 있다.
        storeA.groups[0].snippets[0].content = "A가 덮어씀"
        XCTAssertEqual(storeA.saveNow(), .blockedByRemoteChange)

        let onDisk = try read(file)
        XCTAssertEqual(
            onDisk.groups[0].snippets.map(\.abbreviation), [";one", ";two"],
            "디스크는 여전히 storeB가 쓴 내용이어야 한다"
        )
        XCTAssertEqual(onDisk.groups[0].snippets[0].content, "1")
        XCTAssertEqual(
            storeA.groups[0].snippets[0].content, "A가 덮어씀",
            "A의 인메모리 편집은 손상 없이 그대로여야 한다 — 양쪽 다 살아 있어야 회수할 수 있다"
        )
    }

    /// 한 번 막히면 계속 막혀 있어야 한다. 사용자가 해소하기 전까지 뒤이은 저장이
    /// 슬쩍 통과하면 결국 같은 파괴가 일어난다.
    func testRemoteChangeKeepsBlockingSubsequentSaves() throws {
        let file = scratchPath()
        try write(StoreData(groups: library("Shared", [])), to: file)

        let storeA = Store(fileURL: file, deviceDefaults: makeDefaults())
        let storeB = Store(fileURL: file, deviceDefaults: makeDefaults())

        storeB.groups[0].snippets.append(Snippet(abbreviation: ";b", content: "B"))
        XCTAssertEqual(storeB.saveNow(), .saved)

        storeA.groups[0].snippets.append(Snippet(abbreviation: ";a", content: "A"))
        XCTAssertEqual(storeA.saveNow(), .blockedByRemoteChange)
        XCTAssertEqual(storeA.saveNow(), .blockedByRemoteChange)
        XCTAssertEqual(try read(file).groups[0].snippets.map(\.abbreviation), [";b"])
    }

    // MARK: - AC-CORE-006 — 가드가 과잉 차단하지 않는다

    /// 항상 거부하도록 고정된 가드는 AC-CORE-001을 통과하면서 앱을 벽돌로 만든다.
    /// 양쪽 방향을 다 못 박아야 가드가 진짜 가드다.
    func testGuardDoesNotBlockWhenNobodyElseTouchedTheFile() throws {
        let file = scratchPath()
        let store = Store(fileURL: file, deviceDefaults: makeDefaults())

        store.groups = library("Mine", [Snippet(abbreviation: ";x", content: "first")])
        XCTAssertEqual(store.saveNow(), .saved)
        XCTAssertEqual(try read(file).groups[0].snippets[0].content, "first")

        // 자기 자신의 직전 쓰기를 원격 변경으로 오해하면 안 된다.
        store.groups[0].snippets[0].content = "second"
        XCTAssertEqual(store.saveNow(), .saved)
        XCTAssertEqual(try read(file).groups[0].snippets[0].content, "second")

        store.groups[0].snippets[0].content = "third"
        XCTAssertEqual(store.saveNow(), .saved)
        XCTAssertEqual(try read(file).groups[0].snippets[0].content, "third")
    }

    // MARK: - AC-CORE-003 — 확장이 동기화 파일을 더럽히지 않는다

    /// 확장은 편집이 아니다. 스니펫을 쓰기만 해도 파일이 바뀌면, 아무것도 편집하지
    /// 않은 Mac이 다른 Mac의 편집을 덮어쓰게 된다.
    func testRecordExpansionDoesNotDirtyTheStoreFile() throws {
        let file = scratchPath()
        let defaults = makeDefaults()
        let store = Store(fileURL: file, deviceDefaults: defaults)
        store.groups = library("G", [Snippet(abbreviation: ";a", content: "b")])
        XCTAssertEqual(store.saveNow(), .saved)

        let before = try Data(contentsOf: file)

        for _ in 0..<100 { store.recordExpansion() }
        drainMainQueueAndDebounce()

        XCTAssertEqual(
            try Data(contentsOf: file), before,
            "확장 100회로 파일이 단 한 바이트도 바뀌면 안 된다"
        )
        XCTAssertEqual(store.expansionCount, 100)

        // 다음 실행에서도 유지된다 — 파일이 아니라 UserDefaults가 권위다.
        let relaunched = Store(fileURL: file, deviceDefaults: defaults)
        XCTAssertEqual(relaunched.expansionCount, 100)
    }

    // MARK: - AC-CORE-004 — 포인터 설정 + 파일 부재 = 사용 불가, 첫 실행 아님

    /// iCloud는 안 쓰는 파일을 자리표시자로 축출한다. 그때 경로는 진짜로 존재하지
    /// 않는다. 그걸 첫 실행으로 보면 빈 라이브러리가 331개를 덮고, iCloud가 그
    /// 공백을 모든 Mac으로 전파한다.
    func testConfiguredPointerWithMissingFileIsUnavailableNotFirstLaunch() throws {
        let defaults = makeDefaults()
        let file = scratchPath() // 아직 없다 — 아직 안 내려받은 라이브러리
        defaults.set(file.path, forKey: Store.DeviceStateKey.storeLocationPath)

        let location = Store.resolveLocation(environment: [:], defaults: defaults)
        XCTAssertEqual(location.fileURL.path, file.path)
        XCTAssertTrue(location.expectsExistingLibrary)

        let store = Store(location: location, deviceDefaults: defaults)
        XCTAssertTrue(store.isLibraryUnavailable)
        XCTAssertEqual(store.saveNow(), .blockedByUnavailableLibrary)

        // 편집을 시도하고 디바운스가 지나도 그 경로에 파일이 생기면 안 된다.
        store.groups = [Store.starterGroup()]
        drainMainQueueAndDebounce()
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: file.path),
            "빈 라이브러리를 아직 안 내려받은 파일 위에 쓰면 331개가 증발한다"
        )
    }

    /// 파일이 도착하면 자동으로 살아나야 한다. 사용 불가가 영구 상태이면 그것도
    /// 못 쓰는 앱이다.
    func testUnavailableLibraryRecoversOnceTheFileArrives() throws {
        let defaults = makeDefaults()
        let file = scratchPath()
        defaults.set(file.path, forKey: Store.DeviceStateKey.storeLocationPath)

        let store = Store(
            location: Store.resolveLocation(environment: [:], defaults: defaults),
            deviceDefaults: defaults
        )
        XCTAssertTrue(store.isLibraryUnavailable)

        // iCloud가 실체화했다.
        try write(StoreData(groups: library("Real", [
            Snippet(abbreviation: ";r", content: "331 snippets"),
        ])), to: file)

        XCTAssertTrue(store.retryLoadingStore())
        XCTAssertFalse(store.isLibraryUnavailable)
        XCTAssertEqual(store.groups.map(\.name), ["Real"])
        XCTAssertEqual(store.saveNow(), .saved)
    }

    // MARK: - AC-CORE-005 — 하위 호환: 포인터 미설정 시 현재 릴리스와 동일

    func testWithoutAPointerAMissingFileIsStillAFirstLaunch() throws {
        let defaults = makeDefaults()

        let location = Store.resolveLocation(environment: [:], defaults: defaults)
        XCTAssertEqual(
            location.fileURL,
            FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("SnipKey/store.json")
        )
        XCTAssertFalse(location.expectsExistingLibrary)

        let file = scratchPath()
        let store = Store(fileURL: file, deviceDefaults: defaults)
        XCTAssertFalse(store.isLibraryUnavailable)
        XCTAssertNil(store.loadFailure)

        store.groups = [Store.starterGroup()]
        XCTAssertEqual(store.saveNow(), .saved)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
    }

    // MARK: - AC-SIDE-001 — env가 UserDefaults 포인터를 이긴다

    /// 하네스 격리는 양보 불가다. 이 우선순위가 뒤집히면 e2e가 사용자의 진짜
    /// (그리고 이제 동기화되는) 라이브러리에 키를 쳐 넣는다.
    func testEnvironmentOverrideBeatsTheUserDefaultsPointer() {
        let defaults = makeDefaults()
        defaults.set("/tmp/snipkey-user-sync/store.json", forKey: Store.DeviceStateKey.storeLocationPath)

        let location = Store.resolveLocation(
            environment: [Store.storeDirEnvKey: "/tmp/snipkey-e2e-xyz"],
            defaults: defaults
        )
        XCTAssertEqual(location.fileURL.path, "/tmp/snipkey-e2e-xyz/store.json")
        XCTAssertFalse(
            location.expectsExistingLibrary,
            "하네스 저장소는 비어 있는 게 정상이다 — 사용 불가로 보면 e2e가 첫 실행을 못 한다"
        )
    }

    /// 빈 문자열 포인터는 "설정 안 함"이다. 그대로 받아들이면 사용자가 고르지도
    /// 않은 위치를 기대하며 사용 불가에 빠진다.
    func testEmptyPointerFallsBackToApplicationSupport() {
        let defaults = makeDefaults()
        defaults.set("", forKey: Store.DeviceStateKey.storeLocationPath)

        let location = Store.resolveLocation(environment: [:], defaults: defaults)
        XCTAssertFalse(location.expectsExistingLibrary)
        XCTAssertEqual(location.fileURL.lastPathComponent, "store.json")
        XCTAssertTrue(location.fileURL.path.contains("Application Support"))
    }

    // MARK: - AC-SIDE-003 — 버전 상향 파일은 저장을 막는다

    /// 동기화 파일은 서로 다른 앱 버전의 두 Mac이 함께 만진다. 버전 검사가 없으면
    /// 구버전 앱이 신버전 파일을 자기 스키마로 다시 쓰면서, 모르는 필드를 조용히
    /// 떨어뜨린다.
    func testFileFromANewerBuildBlocksSaving() throws {
        let file = scratchPath()
        var future = StoreData(groups: library("Future", []))
        future.version = 99
        try write(future, to: file)
        let before = try Data(contentsOf: file)

        let store = Store(fileURL: file, deviceDefaults: makeDefaults())
        XCTAssertEqual(store.saveNow(), .blockedByNewerSchema)

        store.groups = library("Downgraded", [])
        drainMainQueueAndDebounce()
        XCTAssertEqual(try Data(contentsOf: file), before, "신버전 파일이 다운그레이드되면 안 된다")
    }

    // MARK: - AC-SIDE-004 — 관용 디코더

    /// 두 Mac의 앱 버전이 다르면 스키마가 갈라지는 게 정상이다. 키 하나 때문에
    /// 라이브러리 전체를 못 읽으면, 그 Mac은 통째로 loadFailure에 빠진다.
    func testDecoderToleratesUnknownKeysAndMissingKnownKeys() throws {
        let raw = Data("""
        {
          "groups": [],
          "somethingFromTheFuture": { "nested": [1, 2, 3] }
        }
        """.utf8)

        let decoded = try JSONDecoder.snipKey.decode(StoreData.self, from: raw)
        XCTAssertTrue(decoded.macros.isEmpty)
        XCTAssertEqual(decoded.expansionCount, 0)
        XCTAssertEqual(decoded.version, 1, "버전 키가 없는 파일은 버전 필드가 생기기 전의 것 = 1")

        // 그리고 그런 파일은 로드 실패가 아니어야 한다.
        let file = scratchPath()
        try raw.write(to: file)
        let store = Store(fileURL: file, deviceDefaults: makeDefaults())
        XCTAssertNil(store.loadFailure)
    }

    // MARK: - AC-SIDE-005 — 기존 사용자의 평생 확장 횟수를 잃지 않는다

    func testExpansionCountIsSeededFromTheExistingFileOnce() throws {
        let file = scratchPath()
        let defaults = makeDefaults()
        try write(StoreData(groups: library("G", []), expansionCount: 4200), to: file)

        let store = Store(fileURL: file, deviceDefaults: defaults)
        XCTAssertEqual(store.expansionCount, 4200, "업그레이드하면서 평생 횟수를 0으로 리셋하면 안 된다")
        XCTAssertEqual(defaults.object(forKey: Store.DeviceStateKey.expansionCount) as? Int, 4200)

        // 시드는 한 번뿐이다. 이후로는 파일 값이 장치 값을 덮으면 안 된다 —
        // 그러면 장치-로컬로 뺀 의미가 사라진다.
        store.recordExpansion()
        drainMainQueueAndDebounce()
        try write(StoreData(groups: library("G", []), expansionCount: 7), to: file)

        let relaunched = Store(fileURL: file, deviceDefaults: defaults)
        XCTAssertEqual(relaunched.expansionCount, 4201)
    }

    /// 온보딩 완료 여부도 같은 방식으로 승계된다. 다만 새 Mac에서는 (UserDefaults가
    /// 비어 있고 라이브러리를 방금 받았으므로) 파일 값을 따라 시드된다는 점은
    /// 알려진 한계다 — REQ-DEV-003의 목적은 M4의 "Link to Snippets…" 경로에서
    /// 달성된다. 여기서는 기존 사용자가 온보딩을 다시 보지 않는 것만 못 박는다.
    func testOnboardingFlagIsSeededFromTheExistingFile() throws {
        let file = scratchPath()
        let defaults = makeDefaults()
        var settings = AppSettings()
        settings.didFinishOnboarding = true
        try write(StoreData(groups: [], settings: settings), to: file)

        let store = Store(fileURL: file, deviceDefaults: defaults)
        XCTAssertTrue(store.didFinishOnboarding, "기존 사용자가 업그레이드했다고 온보딩을 다시 보면 안 된다")
        XCTAssertEqual(defaults.object(forKey: Store.DeviceStateKey.didFinishOnboarding) as? Bool, true)
    }

    /// 온보딩 완료는 장치-로컬이므로 파일을 더럽히지 않는다.
    func testFinishingOnboardingDoesNotDirtyTheStoreFile() throws {
        let file = scratchPath()
        let defaults = makeDefaults()
        let store = Store(fileURL: file, deviceDefaults: defaults)
        store.groups = library("G", [Snippet(abbreviation: ";a", content: "b")])
        XCTAssertEqual(store.saveNow(), .saved)
        let before = try Data(contentsOf: file)

        store.didFinishOnboarding = true
        drainMainQueueAndDebounce()

        XCTAssertEqual(try Data(contentsOf: file), before)
        XCTAssertTrue(Store(fileURL: file, deviceDefaults: defaults).didFinishOnboarding)
    }

    // MARK: - AC-SIDE-006 — 구버전 빌드가 이 빌드의 파일을 여전히 읽는다

    /// pre-2.0 빌드의 `StoreData`를 그대로 재현한 것 — 합성 Codable, 비옵셔널
    /// `expansionCount`. 이 빌드가 그 키를 빼면 구버전 Mac이 라이브러리 전체를
    /// 디코드하지 못하고 통째로 loadFailure에 빠진다.
    private struct LegacyStoreData: Codable {
        var version: Int
        var groups: [SnippetGroup]
        var macros: [HotkeyMacro]
        var settings: AppSettings
        var expansionCount: Int
    }

    func testFilesThisBuildWritesStillDecodeWithAPre2Decoder() throws {
        let file = scratchPath()
        let store = Store(fileURL: file, deviceDefaults: makeDefaults())
        store.groups = [Store.starterGroup()]
        XCTAssertEqual(store.saveNow(), .saved)

        let legacy = try JSONDecoder.snipKey.decode(LegacyStoreData.self, from: Data(contentsOf: file))
        XCTAssertEqual(legacy.groups.count, 1)
        XCTAssertEqual(legacy.expansionCount, 0, "값은 무의미하지만 키는 반드시 있어야 한다")
    }

    // MARK: - AC-SIDE-007 — 기존 loadFailure 가드가 계속 우선한다

    /// 새 가드는 덧붙이는 것이지 갈아치우는 것이 아니다. 읽지 못한 파일은 원격
    /// 변경 여부와 무관하게 여전히 덮으면 안 된다.
    func testLoadFailureKeepsPriorityOverRemoteChange() throws {
        let file = scratchPath()
        try Data("{ broken".utf8).write(to: file)

        let store = Store(fileURL: file, deviceDefaults: makeDefaults())
        XCTAssertNotNil(store.loadFailure)
        if let backup = store.loadFailure?.backupURL { scratchFiles.append(backup) }

        // 그 사이 다른 Mac이 파일을 갈아치웠다.
        try write(StoreData(groups: library("Theirs", [])), to: file)

        XCTAssertEqual(store.saveNow(), .blockedByLoadFailure)
        XCTAssertEqual(try read(file).groups.map(\.name), ["Theirs"])
    }

    /// 읽기 권한조차 없는 파일. `Data(contentsOf:)`가 던지므로 init은 그 파일의
    /// 지문을 영영 모른다 — 이때 "새로 시작"이 쓰기 선결 조건에 막히면, 기존
    /// 복구 경로가 조용히 죽는다. 사용자가 명시적으로 버리기로 한 파일까지
    /// 막는 것은 이 가드의 일이 아니다.
    func testStartingFreshWorksEvenWhenTheOldFileCouldNotBeReadAtAll() throws {
        try XCTSkipIf(getuid() == 0, "root는 권한과 무관하게 읽을 수 있어 이 분기를 못 만든다")

        let file = scratchPath()
        try write(StoreData(groups: library("Old", [Snippet(abbreviation: ";o", content: "old")])), to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: file.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path) }

        let store = Store(fileURL: file, deviceDefaults: makeDefaults())
        XCTAssertNotNil(store.loadFailure, "읽을 수 없는 파일은 로드 실패다")
        if let backup = store.loadFailure?.backupURL { scratchFiles.append(backup) }

        // 이 호출이 내부적으로 saveNow()를 한다. 읽지 못한 파일의 지문을 모른다는
        // 이유로 여기서 막히면, 기존 복구 경로가 조용히 죽는다.
        store.startFreshDiscardingUnreadableStore()
        XCTAssertNil(store.loadFailure)

        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path)
        XCTAssertTrue(
            try read(file).groups.isEmpty,
            "사용자가 명시적으로 버리기로 한 파일은 실제로 비워져야 한다"
        )
    }
}
