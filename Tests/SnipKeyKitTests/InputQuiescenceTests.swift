import XCTest
@testable import SnipKeyKit

/// 큐에 걸린 확장을 버릴지 진행할지 결정하는 층.
///
/// 이 결정을 ExpansionEngine 안에 묻어두면 단위 테스트가 닿지 못한다. KeyClassifier를
/// 꺼냈던 것과 같은 이유로 여기서 값으로 다룬다.
final class InputQuiescenceTests: XCTestCase {

    private func assertAborts(
        _ decision: ExpansionDecision,
        _ message: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard case .abort = decision else {
            return XCTFail("\(message) — 중단이어야 하는데 \(decision) 로 판정했다", file: file, line: line)
        }
    }

    // MARK: - 일반 경로

    /// 종결자를 치고 멈춘 사용자. 무장 이후 키가 없으니 오늘과 똑같이 확장된다.
    /// 가드가 정상 확장을 죽이면 안 된다 — 그건 고치는 게 아니라 망가뜨리는 것이다.
    func testProceedsWhenNoKeyArrivedAfterArming() {
        let sut = InputQuiescenceGuard(armedAt: 10.0)
        XCTAssertEqual(sut.decide(lastRealKeyAt: 9.99), .proceed)   // 종결자 자신
        XCTAssertEqual(sut.decide(lastRealKeyAt: nil), .proceed)    // 아직 아무 키도 없음
    }

    /// 'sig ' 매치 직후에도 'next'를 이어 친 실제 시나리오.
    /// 여기서 진행하면 백스페이스 4번이 'next'를 통째로 먹는다.
    func testAbortsWhenAKeyArrivedAfterArming() {
        let sut = InputQuiescenceGuard(armedAt: 10.0)
        assertAborts(sut.decide(lastRealKeyAt: 10.05), "무장 50ms 뒤에 도착한 키")
    }

    // MARK: - 필인 패널 — Codex가 찾아낸 파괴 경로

    /// 패널을 닫고 포커스가 돌아오는 창에서 사용자가 대상 앱에 타이핑한 경우.
    /// 뒤늦게 나가는 백스페이스가 약어가 아니라 그 글자를 먹는다.
    func testAbortsWhenAKeyLandsDuringTheFocusReactivationWindow() {
        let armedAtDismissal = InputQuiescenceGuard(armedAt: 10.0)
        assertAborts(armedAtDismissal.decide(lastRealKeyAt: 10.10), "재활성화 창에서 도착한 키")
    }

    /// 정숙(quiescence) 모델이 놓쳤던 바로 그 경우 — 그리고 이 테스트의 존재 이유.
    ///
    /// 필인은 패널이 닫힌 뒤 주입까지 400ms 남짓 걸린다. 사용자는 그 안에 단어 하나를
    /// 치고 '멈출' 수 있다. "마지막 키로부터 120ms가 지났는가"로 물으면 이 상황은
    /// "조용하다"고 답하고, 백스페이스가 방금 친 단어를 먹는다. (E2E에서 실제로 그렇게
    /// 터졌다: keepme 를 치고 멈추자 5글자가 지워졌다.)
    ///
    /// 무장 이후 입력 여부로 물으면 사용자가 얼마나 오래 멈췄든 상관없다 — 그 키는
    /// 무장 뒤에 왔고, 그것으로 끝이다.
    func testAbortsWhenTheUserTypedAWordThenWentQuietInsideTheFillInWindow() {
        let armedAtDismissal = InputQuiescenceGuard(armedAt: 10.0)

        // 사용자가 10.02~10.25 동안 'keepme'를 치고 멈춘다. 주입 판정은 10.41.
        let lastKeyOfTheWord = 10.25
        let injectionCheck = 10.41
        XCTAssertGreaterThan(injectionCheck - lastKeyOfTheWord, 0.12, "이 시점엔 '정숙'하다 — 그래서 정숙 모델이 통과시켰다")

        assertAborts(
            armedAtDismissal.decide(lastRealKeyAt: lastKeyOfTheWord),
            "단어를 치고 멈춘 사용자 (정숙하지만 텍스트는 이미 바뀌었다)"
        )
    }

    /// 반대편. 패널을 Return으로 닫고 대상 앱에는 아무것도 치지 않은 정상 필인.
    ///
    /// 패널을 닫은 Return의 '이벤트 시각'은 패널이 닫히기 전이다. 무장은 패널이 닫히는
    /// 순간에 하므로 그 Return은 언제나 무장 이전이고, 우리 탭 콜백이 늦게 돌아도
    /// 마찬가지다. 처리 시각을 기준선으로 삼았다면 바로 이 경우가 잘못 취소됐다.
    func testProceedsWhenThePanelDismissingReturnIsProcessedLate() {
        let returnEventTime = 9.98        // 사용자가 Return을 누른 시각
        let armedAtDismissal = InputQuiescenceGuard(armedAt: 10.0)  // 패널이 닫히며 무장

        // 탭 콜백이 늦게 돌아 10.05에야 이 키를 기록하더라도, 기록되는 값은 '이벤트 시각'이다.
        XCTAssertEqual(armedAtDismissal.decide(lastRealKeyAt: returnEventTime), .proceed)
    }

    // MARK: - 시계

    /// 시계는 마지막 키의 이벤트 시각을 들고, 무장은 '지금'을 기준으로 잡는다.
    func testClockArmsAtNowAndTracksTheMostRecentEventTime() {
        var now: TimeInterval = 100
        let clock = KeystrokeClock(now: { now })

        XCTAssertNil(clock.lastKeyAt)
        XCTAssertEqual(clock.decide(clock.arm()), .proceed)

        clock.mark(at: 99.99)                 // 종결자 — 무장보다 이전
        let quiescence = clock.arm()          // armedAt = 100
        XCTAssertEqual(clock.decide(quiescence), .proceed)

        now = 100.16                          // 인젝터가 정착 시간을 기다린 뒤
        clock.mark(at: 100.05)                // 그 사이 사용자가 이어서 쳤다
        assertAborts(clock.decide(quiescence), "무장 뒤에 도착한 키")
    }

    /// CGEvent.timestamp와 monotonicNow()는 반드시 같은 시간축이어야 한다. 다르면
    /// '무장 이전/이후' 비교가 통째로 무의미해진다.
    ///
    /// 실제로 그렇게 깨뜨린 적이 있다. CGEvent.timestamp를 mach 절대 시간으로 착각하고
    /// 타임베이스(numer/denom)를 곱했더니 값이 40배로 부풀어, 모든 키가 '무장 이후'로
    /// 보이고 모든 확장이 취소됐다(E2E 5/9 실패). CGEvent.timestamp는 mach 절대 시간이
    /// 아니라 '부팅 이후 나노초'이고, DispatchTime.uptimeNanoseconds와 같은 축이다.
    ///
    /// 이 테스트는 그 사실을 못 박는다. 변환이 어긋나면 여기서 잡힌다.
    func testEventTimestampSharesTheSameTimeBaseAsMonotonicNow() {
        let before = KeystrokeClock.monotonicNow()
        // CGEvent.timestamp가 주는 것과 같은 종류의 값(부팅 이후 나노초).
        let eventLike = DispatchTime.now().uptimeNanoseconds
        let after = KeystrokeClock.monotonicNow()

        let converted = KeystrokeClock.seconds(sinceBootNanos: eventLike)
        XCTAssertGreaterThanOrEqual(converted, before)
        XCTAssertLessThanOrEqual(converted, after)
    }

    /// mach 절대 시간으로 착각하고 타임베이스를 곱하면 값이 어떻게 어긋나는지 고정한다.
    /// (Apple Silicon 기준 numer/denom = 125/3 → 약 41.7배)
    func testNanosecondConversionIsNotMachAbsoluteTime() {
        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        guard timebase.numer != timebase.denom else {
            // 타임베이스가 1:1인 하드웨어(구형 Intel)에서는 두 해석이 우연히 같다.
            return
        }

        let raw: UInt64 = 2_705_021_535_549_333            // 실측 CGEvent.timestamp
        let asNanos = KeystrokeClock.seconds(sinceBootNanos: raw)
        let asMach = Double(raw) * Double(timebase.numer) / Double(timebase.denom) / 1_000_000_000

        XCTAssertEqual(asNanos, 2_705_021.535549333, accuracy: 0.001)
        XCTAssertGreaterThan(asMach, asNanos * 10, "mach 해석은 값을 수십 배로 부풀린다")
    }

    /// 시계는 이벤트 탭(메인 런루프)에서 쓰이고 인젝터 큐에서 읽힌다.
    func testClockIsSafeUnderConcurrentMarks() {
        let clock = KeystrokeClock()
        DispatchQueue.concurrentPerform(iterations: 1_000) { i in
            clock.mark(at: TimeInterval(i))
        }
        XCTAssertNotNil(clock.lastKeyAt)
    }
}
