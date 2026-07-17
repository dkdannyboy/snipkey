import XCTest
@testable import SnipKeyKit

/// §3.5 함정의 유일한 방어선. `.atomic` 쓰기는 임시 파일에 쓴 뒤 rename하므로 파일의
/// inode가 매번 교체된다. 파일 fd에 건 DispatchSource는 첫 쓰기 직후 이미 사라진
/// inode를 가리키는 좀비가 되어 조용히 죽는다 — 이후 변경을 영영 못 본다. 그래서
/// 상위 디렉터리를 감시해야 한다. 이 테스트가 없으면 "돌아가는 것처럼 보이지만 첫
/// 변경 뒤로는 먹통"인 감시자가 통과해 버린다.
final class StoreWatcherTests: XCTestCase {

    private var scratchDirs: [URL] = []

    override func tearDown() {
        for dir in scratchDirs { try? FileManager.default.removeItem(at: dir) }
        scratchDirs = []
        super.tearDown()
    }

    private func makeDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("snipkey-watch-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        scratchDirs.append(dir)
        return dir
    }

    // MARK: - AC-CORE-008 — atomic 쓰기 이후에도 감시가 살아 있다

    func testDirectoryWatchSurvivesConsecutiveAtomicRewrites() throws {
        let dir = try makeDir()
        let file = dir.appendingPathComponent("store.json")

        let watcher = DirectoryWatcher(directoryURL: dir)
        // 이벤트는 감시자의 백그라운드 큐에서 온다. 한 번에 하나씩만 기다리려고,
        // 알림이 오면 현재 대기 중인 expectation을 채우고 곧바로 비운다 — 그래야 같은
        // 쓰기가 만든 여러 이벤트가 다음 쓰기의 expectation을 앞당겨 채우지 않는다.
        let gate = NSLock()
        var pending: XCTestExpectation?
        watcher.onChange = {
            gate.lock()
            let e = pending
            pending = nil
            gate.unlock()
            e?.fulfill()
        }
        watcher.start()
        defer { watcher.stop() }

        // 첫 atomic 쓰기 — inode #1 생성.
        gate.lock(); let first = expectation(description: "first atomic write detected"); pending = first; gate.unlock()
        try Data(#"{"version":2,"groups":[]}"#.utf8).write(to: file, options: .atomic)
        wait(for: [first], timeout: 3)

        // 첫 쓰기가 만든 나머지 이벤트가 지나가도록 잠깐 둔다 (pending이 nil이라 무시된다).
        Thread.sleep(forTimeInterval: 0.3)

        // 두 번째 atomic 쓰기 — inode #1을 rename으로 교체(inode #2). fd 감시자라면
        // 여기서 죽어 있어 아무 이벤트도 못 받고 아래 wait가 타임아웃한다.
        gate.lock(); let second = expectation(description: "second atomic write detected"); pending = second; gate.unlock()
        try Data(#"{"version":2,"groups":[{"id":"x"}]}"#.utf8).write(to: file, options: .atomic)
        wait(for: [second], timeout: 3)
    }
}
