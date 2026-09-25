import XCTest
@testable import SnipKeyKit

/// B7: 확장 켜기/끄기는 **Mac마다** 따로다.
///
/// 예전에는 이 값이 동기화되는 파일(settings.expansionEnabled)에 있었다. 한 Mac에서 끄면
/// 파일이 바뀌고, 다른 Mac이 그 파일을 다시 읽는 순간 그쪽도 조용히 꺼졌다 — 사용자는
/// 언제 꺼졌는지도 모른 채 "확장이 안 된다"를 겪었다.
final class DeviceExpansionToggleTests: XCTestCase {

    private var suiteNames: [String] = []
    private var scratchFiles: [URL] = []

    override func tearDown() {
        for name in suiteNames { UserDefaults.standard.removePersistentDomain(forName: name) }
        for url in scratchFiles { try? FileManager.default.removeItem(at: url) }
        super.tearDown()
    }

    private func makeDefaults() -> UserDefaults {
        let name = "snipkey-toggle-\(UUID().uuidString)"
        suiteNames.append(name)
        return UserDefaults(suiteName: name)!
    }

    private func scratchPath() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("snipkey-toggle-\(UUID().uuidString).json")
        scratchFiles.append(url)
        return url
    }

    private func drainMainQueueAndDebounce() {
        let drained = expectation(description: "main queue drained")
        DispatchQueue.main.async { drained.fulfill() }
        wait(for: [drained], timeout: 2)
        Thread.sleep(forTimeInterval: 0.8)
    }

    private func seedLibrary(at file: URL) throws {
        let data = StoreData(groups: [SnippetGroup(name: "g", snippets: [Snippet(abbreviation: ";a", content: "A")])])
        try JSONEncoder.snipKey.encode(data).write(to: file)
    }

    func testTurningExpansionOffOnOneMacLeavesTheOtherOn() throws {
        let file = scratchPath()
        try seedLibrary(at: file)
        let macA = Store(fileURL: file, deviceDefaults: makeDefaults())
        let macB = Store(fileURL: file, deviceDefaults: makeDefaults())

        macA.settings.expansionEnabled = false
        // B가 편집해 파일을 쓰게 한 뒤 A가 그 파일을 다시 읽어도, A는 여전히 꺼져 있고
        macB.groups[0].snippets[0].content = "B-edit"
        XCTAssertEqual(macB.saveNow(), .saved)
        macA.externalChangeDetected()
        drainMainQueueAndDebounce()
        XCTAssertEqual(macA.groups[0].snippets[0].content, "B-edit")
        XCTAssertFalse(macA.settings.expansionEnabled)

        // A가 파일을 써도 B는 여전히 켜져 있다.
        macA.groups[0].snippets[0].content = "A-edit"
        XCTAssertEqual(macA.saveNow(), .saved)
        macB.externalChangeDetected()
        drainMainQueueAndDebounce()
        XCTAssertEqual(macB.groups[0].snippets[0].content, "A-edit")
        XCTAssertTrue(macB.settings.expansionEnabled)
    }

    func testTogglingExpansionIsNotAnEditOfTheSharedFile() throws {
        let file = scratchPath()
        try seedLibrary(at: file)
        let before = try Data(contentsOf: file)
        let store = Store(fileURL: file, deviceDefaults: makeDefaults())

        store.settings.expansionEnabled = false
        drainMainQueueAndDebounce()

        XCTAssertEqual(try Data(contentsOf: file), before, "끄기만 했는데 동기화 파일이 바뀌었다")
    }

    func testChoiceSurvivesRelaunch() throws {
        let file = scratchPath()
        try seedLibrary(at: file)
        let defaults = makeDefaults()
        let first = Store(fileURL: file, deviceDefaults: defaults)
        first.settings.expansionEnabled = false
        drainMainQueueAndDebounce()

        let relaunched = Store(fileURL: file, deviceDefaults: defaults)
        XCTAssertFalse(relaunched.settings.expansionEnabled)
    }

    func testUpgradingUserKeepsTheirLocalFileValue() throws {
        // 로컬 파일에 '꺼짐'이 저장돼 있던 기존 사용자는 업데이트 후에도 꺼진 채여야 한다.
        let file = scratchPath()
        var data = StoreData()
        data.settings.expansionEnabled = false
        try JSONEncoder.snipKey.encode(data).write(to: file)
        let store = Store(fileURL: file, deviceDefaults: makeDefaults())
        XCTAssertFalse(store.settings.expansionEnabled)
    }

    func testNewMacJoiningASyncedLibraryStartsEnabled() throws {
        // 다른 Mac이 꺼 둔 파일을 새 Mac이 연결해도, 새 Mac은 켜진 채로 시작한다.
        let file = scratchPath()
        var data = StoreData()
        data.settings.expansionEnabled = false
        try JSONEncoder.snipKey.encode(data).write(to: file)
        let store = Store(
            location: Store.Location(fileURL: file, expectsExistingLibrary: true),
            deviceDefaults: makeDefaults()
        )
        XCTAssertTrue(store.settings.expansionEnabled)
    }
}
