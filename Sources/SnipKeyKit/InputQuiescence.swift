import Foundation

/// 큐에 걸린 확장을 그대로 진행해도 되는지에 대한 판정.
public enum ExpansionDecision: Equatable {
    /// 매치 이후 실입력이 없었다. 지우고 붙여넣어도 된다.
    case proceed
    /// 매치 이후 사용자가 계속 타이핑했다. 확장을 통째로 버린다.
    case abort(keysTypedAhead: UInt64)
}

/// 확장이 큐에 걸린 순간의 키 카운터를 들고 있다가, 주입 직전의 카운터와 비교해
/// 그 확장을 계속 진행해도 되는지 판정한다.
///
/// 왜 필요한가 — 이벤트 탭이 `.listenOnly`라 사용자의 키는 대상 앱에 '먼저' 도착한다.
/// 확장은 비동기이고 느리다(백스페이스·붙여넣기 사이에 수십~수백 ms의 sleep이 있다).
/// 그래서 'sig ' 가 매치된 뒤에도 사용자가 'next'를 계속 치면, 그 글자들이 이미 앱에
/// 들어간 상태에서 백스페이스 4번이 나간다 — 지워지는 것은 'sig '가 아니라 'next'다.
///
/// 확장이 안 되는 것보다 엉뚱한 자리에서 확장되는 것이 나쁘다. 타이핑을 이어간
/// 사용자는 확장을 못 볼 뿐이고(약어를 다시 치고 잠깐 멈추면 된다), 그 상태로
/// 백스페이스를 맞은 사용자는 자기가 쓴 글자를 조용히, 되돌릴 수 없이 잃는다.
public struct InputQuiescenceGuard: Equatable {

    /// 매치가 발화한 순간의 키 카운터. 종결자 키까지 포함한 값이다.
    public let capturedKeystrokes: UInt64

    public init(capturedKeystrokes: UInt64) {
        self.capturedKeystrokes = capturedKeystrokes
    }

    /// 주입 직전(첫 백스페이스가 나가기 바로 전)에 호출한다.
    ///
    /// 카운터가 조금이라도 달라졌으면 중단이다. '몇 글자까지는 봐준다' 같은 여유는
    /// 두지 않는다 — 한 글자만 들어와도 백스페이스는 이미 한 칸 어긋난다.
    public func decide(currentKeystrokes: UInt64) -> ExpansionDecision {
        guard currentKeystrokes != capturedKeystrokes else { return .proceed }
        // 카운터는 단조 증가라 뒤로 갈 수 없다. 그런 값이 왔다면 우리가 상태를
        // 잘못 읽은 것이므로, 판정을 신뢰할 수 없다 — 그래도 중단이다.
        let ahead = currentKeystrokes > capturedKeystrokes
            ? currentKeystrokes - capturedKeystrokes
            : 0
        return .abort(keysTypedAhead: ahead)
    }
}

/// 실제 사용자 키 입력만 세는 단조 증가 카운터.
///
/// 이벤트 탭 콜백(메인 런루프)에서 올리고 인젝터 큐에서 읽으므로 잠금이 필요하다.
public final class KeystrokeCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value: UInt64 = 0

    public init() {}

    public var current: UInt64 {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    /// 진짜 키가 하나 도착했다. SnipKey가 스스로 쏜 합성 이벤트는 절대 여기 오면 안 된다 —
    /// 인젝터의 백스페이스가 바로 그 확장을 취소해 버린다.
    public func bump() {
        lock.lock()
        value &+= 1
        lock.unlock()
    }

    /// 지금 값을 고정한 가드를 만든다.
    public func snapshot() -> InputQuiescenceGuard {
        InputQuiescenceGuard(capturedKeystrokes: current)
    }
}
