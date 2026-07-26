import XCTest
@testable import SnipKeyKit

/// iCloud 원격 변경 감지 버그 수정의 안전망.
///
/// 배경: `DirectoryWatcher`(kqueue)는 로컬 쓰기는 잡지만 다른 Mac에서 온 iCloud 반영은
/// 놓친다. 그래서 iCloud 위치에서는 `MetadataQueryWatcher`를 함께 세우고, `Store`가
/// 감시자를 하나만 들 수 있으므로 `CompositeWatcher`로 둘을 묶는다.
///
/// 이 테스트들은 실제 iCloud 없이(벽시계 없이) 다중화·배선·감시자 선택을 결정적으로
/// 검증한다. 감시자는 얇게(결정 로직 없음) 두었으므로 주입한 가짜/알림 게시만으로
/// 전 경로를 확인할 수 있다.
final class WatcherCompositionTests: XCTestCase {

    private var suiteNames: [String] = []
    private var scratchFiles: [URL] = []

    override func tearDown() {
        for name in suiteNames { UserDefaults.standard.removePersistentDomain(forName: name) }
        suiteNames = []
        for url in scratchFiles { try? FileManager.default.removeItem(at: url) }
        scratchFiles = []
        super.tearDown()
    }

    private func makeDefaults() -> UserDefaults {
        let name = "snipkey-test-\(UUID().uuidString)"
        suiteNames.append(name)
        guard let defaults = UserDefaults(suiteName: name) else {
            fatalError("UserDefaults suite \(name) could not be created")
        }
        return defaults
    }

    private func scratchPath() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("snipkey-watch-comp-\(UUID().uuidString).json")
        scratchFiles.append(url)
        return url
    }

    private func write(_ data: StoreData, to url: URL) throws {
        try JSONEncoder.snipKey.encode(data).write(to: url)
    }

    private func library(_ name: String, _ snippets: [Snippet]) -> [SnippetGroup] {
        [SnippetGroup(name: name, snippets: snippets)]
    }

    private func drainMainQueueAndDebounce() {
        let drained = expectation(description: "main queue drained")
        DispatchQueue.main.async { drained.fulfill() }
        wait(for: [drained], timeout: 2)
        Thread.sleep(forTimeInterval: 0.8)
    }

    // MARK: - CompositeWatcher — 자식 onChange 다중화

    /// 핵심 계약: 자식 **누구든** 울리면 상위 onChange가 울린다. iCloud 경로에서 로컬
    /// 감시자와 원격 감시자를 함께 물릴 수 있어야 하는 이유 그 자체다.
    func testCompositeWatcherForwardsEachChildOnChange() {
        let childA = FakeWatcher()
        let childB = FakeWatcher()
        let composite = CompositeWatcher([childA, childB])

        var fired = 0
        composite.onChange = { fired += 1 }

        childA.fire()
        childB.fire()
        childA.fire()

        XCTAssertEqual(fired, 3, "자식 셋의 발화가 모두 상위로 전달돼야 한다")
    }

    /// start/stop이 모든 자식에게 전파돼야 한다 — 하나라도 안 서면 그 채널은 먹통이다.
    func testCompositeWatcherStartStopPropagateToChildren() {
        let childA = FakeWatcher()
        let childB = FakeWatcher()
        let composite = CompositeWatcher([childA, childB])

        composite.start()
        XCTAssertTrue(childA.started)
        XCTAssertTrue(childB.started)

        composite.stop()
        XCTAssertFalse(childA.started)
        XCTAssertFalse(childB.started)
    }

    /// 상위 onChange가 아직 없을 때 자식이 울려도 안전해야 한다(초기화 중 발화).
    func testCompositeWatcherFiringBeforeParentOnChangeIsHarmless() {
        let child = FakeWatcher()
        let composite = CompositeWatcher([child])
        // onChange 미설정 상태에서 발화 — 크래시 없이 무시돼야 한다.
        child.fire()
        // 이후 설정하면 정상 전달된다.
        var fired = 0
        composite.onChange = { fired += 1 }
        child.fire()
        XCTAssertEqual(fired, 1)
    }

    // MARK: - MetadataQueryWatcher — 알림 → onChange 배선

    /// 주입한 NotificationCenter로 `.NSMetadataQueryDidUpdate`를 게시하면 onChange가
    /// 울리고, stop 이후에는 더 이상 울리지 않아야 한다. 실제 iCloud 없이 배선만 검증한다.
    func testMetadataQueryWatcherForwardsUpdateNotification() {
        let center = NotificationCenter()
        let watcher = MetadataQueryWatcher(
            fileURL: scratchPath(), notificationCenter: center
        )

        var fired = 0
        watcher.onChange = { fired += 1 }
        watcher.start()

        center.post(name: .NSMetadataQueryDidUpdate, object: watcher.query)
        center.post(name: .NSMetadataQueryDidFinishGathering, object: watcher.query)
        XCTAssertEqual(fired, 2, "Update와 FinishGathering 모두 onChange로 이어져야 한다")

        watcher.stop()
        center.post(name: .NSMetadataQueryDidUpdate, object: watcher.query)
        XCTAssertEqual(fired, 2, "stop 이후에는 관찰자가 해제돼 더 울리면 안 된다")
    }

    /// iCloud가 아닌 파일에서도 start/stop이 크래시 없이 안전해야 한다(헤드리스·CLI 경로).
    func testMetadataQueryWatcherStartStopIsSafeForNonUbiquitousFile() {
        let watcher = MetadataQueryWatcher(fileURL: scratchPath())
        watcher.start()
        watcher.stop()
        // 중복 stop도 no-op.
        watcher.stop()
    }

    // MARK: - iCloud 위치 판정 및 감시자 선택

    /// 순수 로컬 경로는 false, iCloud Drive 경로 모양은 true. 파일이 실제로 없어도
    /// 경로 모양 방어선이 iCloud를 잡아낸다.
    func testIsUbiquitousLocationDetectsLocalAndCloudPaths() {
        let local = scratchPath()
        XCTAssertFalse(Store.isUbiquitousLocation(local))

        let cloud = URL(fileURLWithPath:
            "/Users/tester/Library/Mobile Documents/com~apple~CloudDocs/snipkey/SnipKey-snippets.json")
        XCTAssertTrue(Store.isUbiquitousLocation(cloud))
    }

    /// 기본 팩토리는 위치에 따라 감시자 종류를 고른다: 로컬이면 DirectoryWatcher 단독,
    /// iCloud면 CompositeWatcher(로컬+원격).
    func testDefaultWatcherFactorySelectsWatcherByLocation() {
        let localWatcher = Store.defaultWatcherFactory(scratchPath())
        XCTAssertTrue(localWatcher is DirectoryWatcher,
                      "로컬 경로는 DirectoryWatcher 단독이어야 한다(추가 비용 0)")
        XCTAssertFalse(localWatcher is CompositeWatcher)

        let cloud = URL(fileURLWithPath:
            "/Users/tester/Library/Mobile Documents/com~apple~CloudDocs/snipkey/SnipKey-snippets.json")
        let cloudWatcher = Store.defaultWatcherFactory(cloud)
        XCTAssertTrue(cloudWatcher is CompositeWatcher,
                      "iCloud 경로는 CompositeWatcher(Directory+MetadataQuery)여야 한다")
    }

    // MARK: - 통합 특성화 — 외부 변경이 CompositeWatcher를 통해 리로드를 구동한다

    /// end-to-end: iCloud 경로에서 쓰는 CompositeWatcher를 Store에 주입하고, 그 안의
    /// 원격 채널(가짜)이 울리면 Store가 디스크를 다시 읽어 반영한다. 이것이 원래 버그
    /// ("다른 Mac 저장이 재시작 전까지 안 뜸")가 고쳐졌음을 벽시계 없이 증명한다.
    func testExternalChangeThroughCompositeWatcherDrivesReload() throws {
        let file = scratchPath()
        try write(StoreData(groups: library("Shared", [
            Snippet(abbreviation: ";one", content: "1"),
        ])), to: file)

        // "원격 iCloud 채널"을 대신하는 가짜를 Composite로 감싼다 — 실제 iCloud 위치에서
        // MetadataQueryWatcher가 놓이는 바로 그 자리다.
        let remoteChannel = FakeWatcher()
        let store = Store(
            location: Store.Location(fileURL: file, expectsExistingLibrary: false),
            deviceDefaults: makeDefaults(),
            watcherFactory: { _ in CompositeWatcher([remoteChannel]) }
        )

        // 다른 Mac이 파일을 갱신했다(로컬 kqueue는 못 볼 수 있는 변경).
        try write(StoreData(groups: library("Shared", [
            Snippet(abbreviation: ";one", content: "1"),
            Snippet(abbreviation: ";two", content: "2"),
        ])), to: file)

        // 원격 채널이 울린다 → Composite → Store.externalChangeDetected → 리로드.
        remoteChannel.fire()
        drainMainQueueAndDebounce()

        XCTAssertEqual(store.groups[0].snippets.map(\.abbreviation), [";one", ";two"],
                       "원격 변경이 CompositeWatcher를 타고 반영돼야 한다")
        XCTAssertNil(store.remoteChange, "깨끗한 리로드라 충돌 표시가 없어야 한다")
    }
}
