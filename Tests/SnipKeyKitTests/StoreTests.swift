import XCTest
@testable import SnipKeyKit

/// `Store.defaultFileURL()`의 경로 결정 로직. 하네스가 사용자의 실제 스니펫
/// 라이브러리를 덮어쓰지 않으려면 이 분기가 정확해야 하므로, 두 갈래를 모두 고정한다.
final class StoreDefaultFileURLTests: XCTestCase {

    /// 사용자의 진짜 저장소 위치. 이 값이 바뀌면 기존 사용자의 라이브러리가
    /// 통째로 사라져 보이므로, 상수처럼 못 박아 둔다.
    private var realStoreURL: URL {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SnipKey/store.json")
    }

    func testUsesApplicationSupportWhenOverrideIsUnset() {
        let url = Store.defaultFileURL(environment: [:])
        XCTAssertEqual(url, realStoreURL)
    }

    func testOverrideRedirectsStoreIntoGivenDirectory() {
        let url = Store.defaultFileURL(
            environment: [Store.storeDirEnvKey: "/tmp/snipkey-e2e-xyz"]
        )
        XCTAssertEqual(url.path, "/tmp/snipkey-e2e-xyz/store.json")
        XCTAssertNotEqual(url, realStoreURL)
    }

    /// 빈 문자열은 "설정 안 함"으로 취급해야 한다. 그대로 받아들이면 "/store.json",
    /// 즉 루트에 쓰려다 실패한다.
    func testEmptyOverrideFallsBackToApplicationSupport() {
        let url = Store.defaultFileURL(environment: [Store.storeDirEnvKey: ""])
        XCTAssertEqual(url, realStoreURL)
    }

    /// 기본 인자가 실제 프로세스 환경을 읽는지 확인한다. 위 테스트들은 사전을
    /// 주입하므로, 앱이 인자 없이 호출하는 경로는 여기서만 검증된다.
    func testDefaultArgumentReadsProcessEnvironment() throws {
        let dir = NSTemporaryDirectory() + "snipkey-env-branch"
        setenv(Store.storeDirEnvKey, dir, 1)
        defer { unsetenv(Store.storeDirEnvKey) }

        XCTAssertEqual(Store.defaultFileURL().path, dir + "/store.json")

        unsetenv(Store.storeDirEnvKey)
        XCTAssertEqual(Store.defaultFileURL(), realStoreURL)
    }

    /// 오버라이드된 경로로 Store를 만들면 그 파일에만 쓴다 — 진짜 라이브러리는
    /// 건드리지 않는다. 하네스 안전성의 핵심 보장이다.
    func testStoreWritesOnlyToOverriddenPath() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("snipkey-store-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let url = Store.defaultFileURL(environment: [Store.storeDirEnvKey: dir.path])
        let store = Store(fileURL: url)
        store.groups = [SnippetGroup(name: "E2E", snippets: [
            Snippet(abbreviation: ";e2e", content: "expanded-ok")
        ])]
        XCTAssertEqual(store.saveNow(), .saved)

        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        let reloaded = Store(fileURL: url)
        XCTAssertEqual(reloaded.matcher.match(buffer: ";e2e")?.content, "expanded-ok")
    }
}
