import Foundation

/// 물리 키 배열을 인식하는 병렬 버퍼.
///
/// TextExpander처럼, 사용자가 실제로 누른 물리 QWERTY 키가 영문 약어의 철자를
/// 이루면 — 지금 IME가 한글이라 화면에는 ";칟마" 같은 다른 글자가 찍히더라도 —
/// 확장이 발화해야 한다. 이를 위해 키 입력마다 두 가지를 나란히 보관한다.
///
///   - composed: 이 키가 화면에 만든 문자열(IME 조합 결과, 조합 중 jamo 포함).
///     엔진의 기존 표시 버퍼와 같은 재료다.
///   - physical: 같은 키를 US/ANSI 배열로 해석한 물리 문자.
///
/// 표시 버퍼 매칭이 기존 동작 그대로 '우선'하고(영문/ABC 모드에서 두 버퍼는
/// 동일하다), 표시 버퍼가 매치되지 않을 때만 물리 버퍼로 넘어간다. 이 우선순위가
/// 영문 모드에서의 이중 확장을 원천 차단한다.
public struct LayoutBuffer {
    /// 키 입력 하나의 (표시 기여분, 물리 문자) 쌍.
    public struct Keystroke: Equatable {
        public let composed: String
        public let physical: Character
        public init(composed: String, physical: Character) {
            self.composed = composed
            self.physical = physical
        }
    }

    private var keystrokes: [Keystroke]
    private let maxCount: Int

    public init(maxCount: Int = 64) {
        self.keystrokes = []
        self.maxCount = maxCount
    }

    /// 물리 키 문자열. 매처에 두 번째 버퍼로 그대로 먹인다.
    public var physical: String { String(keystrokes.map(\.physical)) }

    /// 표시 기여분을 이어붙인 문자열(테스트·삭제 수 계산용). 엔진은 기존 동작
    /// 보존을 위해 자체 String 버퍼를 따로 들고 있으므로 매칭에는 그쪽을 쓴다.
    public var composed: String { keystrokes.map(\.composed).joined() }

    public var isEmpty: Bool { keystrokes.isEmpty }
    public var count: Int { keystrokes.count }

    /// 타이핑된 글자 하나를 추가한다. `physical`이 US 배열 대응 문자다.
    public mutating func appendLiteral(composed: String, physical: Character) {
        keystrokes.append(Keystroke(composed: composed, physical: physical))
        if keystrokes.count > maxCount {
            keystrokes.removeFirst(keystrokes.count - maxCount)
        }
    }

    /// 백스페이스 한 번. 마지막 키 입력을 되돌린다.
    public mutating func deleteLast() {
        if !keystrokes.isEmpty { keystrokes.removeLast() }
    }

    /// 버퍼를 통째로 비운다(취소 키·포커스 이동·매치 성사 등).
    public mutating func clear() {
        keystrokes.removeAll(keepingCapacity: true)
    }

    /// 버퍼 끝 `n`개 키 입력이 '화면에 만든' 보이는 글자 수.
    ///
    /// 물리 매치는 물리 키 개수(예: ";clear" = 6)를 백스페이스 수로 돌려주지만,
    /// 한글 IME에서는 그 키들이 화면에 더 적은 수의 조합 글자(";칟ㅁㄱ" = 4개)를
    /// 만든다. 실제로 지워야 하는 것은 '화면에 보이는' 글자다.
    ///
    /// 계산은 IME가 이벤트 탭에 돌려주는 문자(실기에서는 조합되지 않는 호환 자모)에
    /// 의존하지 않고, 각 키의 '물리 문자'를 두벌식 자모로 매핑해 조합 오토마톤
    /// (`HangulComposer`)에 통과시켜 결정론적으로 화면 글자 수를 센다. 표시 버퍼의
    /// NFC 형태에 의존하던 옛 방식은 실기에서 6을 반환해 앞 텍스트를 먹었다.
    ///
    /// @MX:NOTE: [AUTO] 화면 글자 수는 물리 키에서 결정론적으로 계산한다(HangulComposer).
    ///           IME 출력에 의존하지 않으므로 호환 자모를 방출하는 입력기에서도 정확하다.
    public func visibleGraphemeCount(lastKeystrokes n: Int) -> Int {
        guard n > 0 else { return 0 }
        let take = min(n, keystrokes.count)
        let physicalKeys = keystrokes.suffix(take).map(\.physical)
        return HangulComposer.glyphCount(physicalKeys: physicalKeys)
    }

    /// 마지막 키 입력이 화면에 만든 문자열(표시 종결자). 물리 맨몸 약어가 발화할
    /// 때, 화면의 종결자를 지웠다가 확장 뒤에 다시 찍기 위해 쓴다.
    public func lastComposed() -> String {
        keystrokes.last?.composed ?? ""
    }
}

/// 표시 버퍼·물리 버퍼 중 무엇으로 발화했는지, 그리고 화면 기준으로 몇 글자를
/// 지우고 어떤 종결자를 다시 찍어야 하는지를 담은 결정.
public struct BufferMatchDecision {
    public enum Source: Equatable { case composed, physical }

    public let match: Store.Matcher.Match
    public let source: Source
    /// 화면에서 실제로 지울 글자 수.
    public let backspaces: Int
    /// 확장 내용 뒤에 다시 찍을 종결자(화면 기준).
    public let terminator: String

    public init(match: Store.Matcher.Match, source: Source, backspaces: Int, terminator: String) {
        self.match = match
        self.source = source
        self.backspaces = backspaces
        self.terminator = terminator
    }
}

/// 물리 버퍼 폴백을 켜도 되는 입력 소스(IME)인지 판정하는 순수 술어.
///
/// 물리 키 기반 매칭의 삭제 수 계산은 두벌식 전용 조합 오토마톤(`HangulComposer`)에
/// 의존한다. 세벌식(3-Set)은 같은 물리 키를 다른 jamo로 매핑하므로, 오토마톤이 화면
/// 글자 수를 틀리게 세어 앞 텍스트를 먹는다(오삭제 → 훼손). 일본어(로마자)·중국어
/// (병음) 등 조합형 IME도 조합 도중 엉뚱한 물리 키열이 오확장을 일으킬 수 있다.
/// 그래서 물리 폴백은 '정확히' 두벌식 하나에서만 허용한다. 라틴 배열(ABC/US)은
/// 표시 버퍼와 물리 버퍼가 동일하므로 이 게이트와 무관하게 기존대로 동작한다.
///
/// TIS가 입력 소스 ID를 못 읽어 빈 문자열/미지 값이 들어오면 false를 돌려주므로,
/// 호출부가 페일세이프(물리 폴백 OFF)로 동작한다.
///
/// @MX:NOTE: [AUTO] 물리 폴백 화이트리스트는 두벌식(com.apple.inputmethod.Korean.2SetKorean)
///           단 하나. 세벌식·일본어·중국어·미지 IME는 모두 제외한다.
/// @MX:REASON: HangulComposer가 두벌식 전용 오토마톤이라, 다른 배열/IME에서는 삭제
///             글자 수를 틀리게 계산해 사용자 텍스트를 훼손한다. 미래에 세벌식 전용
///             오토마톤이 추가되면 이 화이트리스트를 넓힐 수 있다.
public func isTwoSetKoreanSourceID(_ id: String) -> Bool {
    id == "com.apple.inputmethod.Korean.2SetKorean"
}

/// 두 버퍼 중 무엇으로 확장을 발화할지 결정하는 순수 함수. CGEvent 콜백에서
/// 분리해 실제 이벤트 탭 없이 단위 테스트한다 — 코드베이스가 워처에서 결정
/// 로직을 꺼내 테스트하는 방식과 같다.
///
/// @MX:NOTE: [AUTO] 표시 버퍼 우선 → (게이트 통과 시) 물리 버퍼 폴백. 영문/ABC 모드에서
///           두 버퍼가 동일할 때 이중 확장을 막고, `allowPhysicalFallback`으로 두벌식이
///           아닌 IME에서는 물리 폴백을 통째로 끈다(오확장·오삭제 방지).
public enum LayoutAwareMatcher {
    public static func decide(
        composedBuffer: String,
        layout: LayoutBuffer,
        matcher: Store.Matcher,
        allowPhysicalFallback: Bool
    ) -> BufferMatchDecision? {
        // (1) 표시 버퍼 우선. 기존 동작을 한 글자도 바꾸지 않는다. 영문/ABC 모드에서는
        //     두 버퍼가 동일하므로 여기서 반드시 먼저 잡혀 이중 확장이 원천 차단된다.
        //     이 경로는 게이트와 무관하다 — 항상 기능 도입 이전과 동일하게 동작한다.
        if let m = matcher.match(buffer: composedBuffer) {
            return BufferMatchDecision(
                match: m, source: .composed,
                backspaces: m.backspaces, terminator: m.terminator
            )
        }

        // 물리 폴백 게이트. 두벌식이 아니면(세벌식·일본어·중국어·미지 IME) 여기서 멈춰
        // 표시 버퍼 매칭만 수행한 것과 완전히 동일하게 nil을 돌려준다(기능 도입 이전 동작).
        guard allowPhysicalFallback else { return nil }

        // (2) 물리 버퍼. 표시 버퍼가 매치되지 않을 때만 넘어온다 — 한글 IME처럼
        //     화면 글자와 물리 키가 어긋난 경우다.
        if !layout.isEmpty, let m = matcher.match(buffer: layout.physical) {
            // 백스페이스는 물리 키 수가 아니라 '화면에 보이는 글자 수'로 계산한다.
            let visible = layout.visibleGraphemeCount(lastKeystrokes: m.backspaces)
            // 맨몸 약어는 물리 종결자(1키)를 함께 지웠으므로, 화면의 종결자를 다시 찍는다.
            // 구두점 시작 약어는 종결자가 없다("").
            let terminator = m.terminator.isEmpty ? "" : layout.lastComposed()
            return BufferMatchDecision(
                match: m, source: .physical,
                backspaces: visible, terminator: terminator
            )
        }

        return nil
    }
}
