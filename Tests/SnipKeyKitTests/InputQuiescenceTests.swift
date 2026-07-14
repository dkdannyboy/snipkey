import XCTest
@testable import SnipKeyKit

/// 큐에 걸린 확장을 버릴지 진행할지 결정하는 층.
///
/// 이 결정을 ExpansionEngine 안에 묻어두면 단위 테스트가 닿지 못한다. KeyClassifier를
/// 꺼냈던 것과 같은 이유로 여기서 값으로 다룬다.
final class InputQuiescenceTests: XCTestCase {

    // MARK: - 진행

    /// 매치 이후 아무 키도 오지 않았다면 오늘과 똑같이 확장한다.
    /// 가드가 정상 확장을 죽이면 안 된다 — 그건 고치는 게 아니라 망가뜨리는 것이다.
    func testProceedsWhenNoKeyArrivedAfterTheMatch() {
        let sut = InputQuiescenceGuard(capturedKeystrokes: 7)
        XCTAssertEqual(sut.decide(currentKeystrokes: 7), .proceed)
    }

    // MARK: - 중단

    /// 단 한 글자라도 뒤이어 들어왔으면 확장을 버린다. 그 한 글자는 이미 앱에
    /// 도착했고, 백스페이스는 약어가 아니라 그 글자를 지우게 된다.
    func testAbortsWhenASingleKeyArrivedAfterTheMatch() {
        let sut = InputQuiescenceGuard(capturedKeystrokes: 7)
        XCTAssertEqual(sut.decide(currentKeystrokes: 8), .abort(keysTypedAhead: 1))
    }

    /// 'sig ' 가 매치된 뒤(s·i·g·space = 4키) 사용자가 'next'를 이어 친 실제 시나리오.
    /// 여기서 진행하면 백스페이스 4번이 'next'를 통째로 먹는다.
    func testAbortsWhenTheUserTypedAWholeWordAhead() {
        let atMatch = InputQuiescenceGuard(capturedKeystrokes: 4)
        XCTAssertEqual(atMatch.decide(currentKeystrokes: 8), .abort(keysTypedAhead: 4))
    }

    /// 카운터가 뒤로 가는 일은 없어야 하지만, 그렇더라도 '진행'으로 넘어가서는 안 된다.
    /// 판정을 못 하겠으면 확장을 포기하는 쪽이 안전하다.
    func testAbortsWhenTheCounterIsInconsistent() {
        let sut = InputQuiescenceGuard(capturedKeystrokes: 9)
        XCTAssertEqual(sut.decide(currentKeystrokes: 3), .abort(keysTypedAhead: 0))
    }

    // MARK: - 카운터

    /// 스냅샷은 그 순간의 값을 고정한다. 이후 키가 들어오면 같은 가드가 중단으로 뒤집힌다.
    func testSnapshotFreezesTheCounterAtCaptureTime() {
        let counter = KeystrokeCounter()
        counter.bump()
        counter.bump()

        let atMatch = counter.snapshot()
        XCTAssertEqual(atMatch.decide(currentKeystrokes: counter.current), .proceed)

        counter.bump()
        XCTAssertEqual(atMatch.decide(currentKeystrokes: counter.current), .abort(keysTypedAhead: 1))
    }

    /// 카운터는 이벤트 탭(메인 런루프)에서 올라가고 인젝터 큐에서 읽힌다.
    func testCounterIsSafeUnderConcurrentBumps() {
        let counter = KeystrokeCounter()
        DispatchQueue.concurrentPerform(iterations: 1_000) { _ in counter.bump() }
        XCTAssertEqual(counter.current, 1_000)
    }
}
