import Foundation

/// 큐에 걸린 확장을 그대로 진행해도 되는지에 대한 판정.
public enum ExpansionDecision: Equatable {
    /// 가드를 무장한 뒤로 사용자 입력이 하나도 없었다. 지우고 붙여넣어도 된다.
    case proceed
    /// 무장 이후에 사용자가 대상 앱에 입력을 넣었다(키 입력이든 마우스 클릭이든).
    /// 확장을 통째로 버린다. `inputArrivedAt`은 그 마지막 입력의 시각(로그용).
    case abort(inputArrivedAt: TimeInterval)
}

/// "지금 지워도 되는가"를 판정한다.
///
/// 묻는 질문은 하나다: **무장한 시점 이후에 대상 앱으로 들어간 사용자 입력이 있는가.**
/// 있으면 버린다. 여기서 '입력'은 커서를 옮길 수 있는 모든 실사용자 이벤트 —
/// 키 입력과 마우스 클릭 — 을 아우른다.
///
/// 왜 이 장치가 필요한가 — 이벤트 탭이 `.listenOnly`라 사용자의 입력은 대상 앱에 '먼저'
/// 도착한다. 확장은 비동기이고 느리다. 'sig ' 가 매치된 뒤에도 사용자가 'next'를 계속
/// 치면, 그 글자들이 이미 앱에 들어간 상태에서 백스페이스 4번이 나간다 — 지워지는 것은
/// 'sig '가 아니라 'next'다. 마우스 클릭도 똑같이 위험하다: 클릭은 키를 하나도 남기지
/// 않으면서 커서를 다른 위치로 옮기므로, 뒤이어 나가는 백스페이스가 그 클릭한 자리를
/// 지운다(같은 앱이라 PID 검사도 통과한다). 확장이 안 되는 것보다 엉뚱한 자리에서
/// 확장되는 것이 나쁘다. 입력을 이어간 사용자는 확장을 못 볼 뿐이지만(다시 치고 잠깐
/// 멈추면 된다), 그 상태로 백스페이스를 맞은 사용자는 자기가 쓴 글자를 조용히, 되돌릴
/// 수 없이 잃는다.
///
/// 왜 '정숙 시간'이 아니라 '무장 이후 입력 여부'인가 — 한때 "마지막 입력으로부터 N ms가
/// 지났는가"로 판정했다. 그 모델은 파괴 창이 짧은 일반 경로에서는 통하지만(계속 치는
/// 사용자는 계속 시끄러우니까) 필인 경로에서 무너진다. 패널이 닫힌 뒤 주입까지 400ms
/// 남짓 걸리는데, 사용자는 그 안에 단어 하나를 치고 '멈출' 수 있다. 그러면 정숙 검사는
/// "조용하다"고 답하고, 백스페이스가 방금 친 그 단어를 먹는다. 임계값을 올려도 소용없다 —
/// 사용자는 언제나 그보다 더 오래 멈출 수 있다. 정숙은 '사용자가 지금 쉬고 있는가'를
/// 묻지만, 백스페이스를 지키는 질문은 '내가 재던 그 텍스트가 그대로인가'이다.
///
/// 왜 '카운터'가 아니라 '이벤트 시각'인가 — 무장 이후 입력 여부는 카운터로도 잴 수
/// 있다. 카운터의 진짜 문제는 세는 것이 아니라 기준선이었다. 기준선을 '우리 탭 콜백이
/// 돈 시각'에 맞추면 필인 패널을 닫는 Return과 경합한다: 콜백이 늦게 돌면 그 Return이
/// 기준선 뒤로 밀려 세어지고, 멀쩡한 필인 확장이 취소된다. 그래서 기준선을 앞뒤로
/// 미는 줄다리기가 시작된다.
///
/// CGEvent가 들고 오는 '하드웨어 타임스탬프'를 쓰면 그 경합 자체가 없어진다. 패널을
/// 닫은 Return의 이벤트 시각은 패널이 닫히기 '전'이다 — 우리 콜백이 언제 돌든 변하지
/// 않는다. 패널이 닫히는 순간 무장하면 그 Return은 언제나 무장 이전이고, 포커스가
/// 돌아온 뒤에 친 입력은 언제나 무장 이후다. 마우스 클릭 역시 같은 시간축을 쓴다.
public struct InputQuiescenceGuard: Equatable {

    /// 이 시각 이후에 도착한 사용자 입력이 있으면 확장을 버린다.
    public let armedAt: TimeInterval

    public init(armedAt: TimeInterval) {
        self.armedAt = armedAt
    }

    /// 주입 직전(첫 백스페이스가 나가기 바로 전)에 호출한다.
    ///
    /// - Parameter lastInputAt: 마지막 '진짜' 사용자 입력(키 또는 클릭)의 **이벤트 시각**.
    ///   우리가 그 이벤트를 처리한 시각이 아니다. nil이면 아직 아무 입력도 관측하지 않았다.
    public func decide(lastInputAt: TimeInterval?) -> ExpansionDecision {
        guard let lastInputAt, lastInputAt > armedAt else { return .proceed }
        return .abort(inputArrivedAt: lastInputAt)
    }
}

/// 마지막 '진짜' 사용자 입력(키 또는 마우스 클릭)의 이벤트 시각만 들고 있는 시계.
///
/// 이벤트 탭 콜백(메인 런루프)에서 쓰고 인젝터 큐에서 읽으므로 잠금이 필요하다.
public final class InputClock: @unchecked Sendable {
    private let lock = NSLock()
    private var last: TimeInterval?
    private let clock: () -> TimeInterval

    /// 부팅 이후 나노초 → 초.
    ///
    /// CGEvent.timestamp가 쓰는 단위가 이것이다. mach 절대 시간(mach_absolute_time)이
    /// 아니다 — 타임베이스(numer/denom)를 곱하면 값이 40배 가까이 부풀어서 모든 입력이
    /// '무장 이후'로 보이고, 결국 모든 확장이 취소된다. 실측으로 확인했다:
    ///   raw=2705021535549333 → /1e9 = 2705021.535초, 같은 순간의 DispatchTime = 2705021.538초.
    public static func seconds(sinceBootNanos nanos: UInt64) -> TimeInterval {
        Double(nanos) / 1_000_000_000
    }

    /// 벽시계(Date)가 아니라 단조 시계를 쓴다. NTP 보정이나 시간대 변경이 확장 판정을
    /// 뒤집어서는 안 된다. CGEvent.timestamp와 같은 시간축이어야 비교가 성립한다 —
    /// DispatchTime.uptimeNanoseconds도 '부팅 이후 나노초'다.
    public static func monotonicNow() -> TimeInterval {
        seconds(sinceBootNanos: DispatchTime.now().uptimeNanoseconds)
    }

    public init(now: @escaping () -> TimeInterval = InputClock.monotonicNow) {
        self.clock = now
    }

    /// 진짜 사용자 입력이 하나 도착했다 — 키든 마우스 클릭이든. 반드시 그 이벤트의
    /// **이벤트 시각**을 넘겨야 한다. 우리가 콜백에서 관측한 시각을 넘기면 패널 종료
    /// 키와의 경합이 되살아난다.
    ///
    /// SnipKey가 스스로 쏜 합성 이벤트는 절대 여기 오면 안 된다. 오면 인젝터의 첫
    /// 백스페이스가 바로 그 확장을 스스로 취소해 버린다. (합성 키는 magicUserData로
    /// 걸러지고, 우리는 합성 마우스 이벤트를 아예 쏘지 않는다.)
    ///
    /// 저장값은 '가장 최신 이벤트 시각'이다 — 마지막으로 처리한 콜백의 시각이 아니라.
    /// 이벤트 콜백이 순서를 뒤집어 도착하면(오래된 이벤트가 나중에 처리) 그냥 덮어쓰기는
    /// 시각을 뒤로 밀어, 무장 이후에 분명히 있었던 입력을 지워버린다. 그러면 decide가
    /// 잘못 proceed를 내고 백스페이스가 옮겨간 커서 자리를 파괴한다. max로 못 박는다.
    public func mark(at eventTime: TimeInterval) {
        lock.lock()
        last = Swift.max(last ?? eventTime, eventTime)
        lock.unlock()
    }

    public var lastInputAt: TimeInterval? {
        lock.lock()
        defer { lock.unlock() }
        return last
    }

    /// 지금을 기준으로 가드를 무장한다. 이 순간 이후에 도착하는 입력이 확장을 취소시킨다.
    public func arm() -> InputQuiescenceGuard {
        InputQuiescenceGuard(armedAt: clock())
    }

    public func decide(_ quiescence: InputQuiescenceGuard) -> ExpansionDecision {
        quiescence.decide(lastInputAt: lastInputAt)
    }
}
