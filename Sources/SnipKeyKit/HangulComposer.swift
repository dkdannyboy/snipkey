import Foundation

/// 물리 QWERTY 키를 두벌식으로 해석했을 때 '화면에 찍히는' 한글(및 비-자모) 글자를
/// 결정론적으로 재구성하는 순수 조합 오토마톤. Carbon/AppKit 의존이 없어 단위
/// 테스트가 쉽다.
///
/// 왜 필요한가: `.listenOnly` 이벤트 탭의 `keyboardGetUnicodeString(...)`은 IME가
/// 화면에 실제로 조합해 보여주는 완성형 글자를 돌려주지 않는다. 키마다 낱개 문자(실기
/// 에서는 호환 자모 U+31xx)를 돌려줄 뿐이라, 물리 키 6개가 화면에서 몇 글자로
/// 조합됐는지 그 출력만으로는 알 수 없다. 그래서 삭제할 백스페이스 수를 IME 출력에
/// 의존하지 않고, 물리 키에서 직접(두벌식 매핑 + 조합 오토마톤) 계산한다.
///
/// @MX:ANCHOR: [AUTO] 물리 매치의 백스페이스 수는 전적으로 이 오토마톤이 정한다.
/// @MX:REASON: [AUTO] LayoutBuffer.visibleGraphemeCount → LayoutAwareMatcher.decide →
///             ExpansionEngine 주입까지 이 계산값이 '화면에서 지울 글자 수'로 흐른다.
///             틀리면 사용자의 앞 텍스트를 먹으므로 입력 정확성의 불변 계약이다.
public enum HangulComposer {

    // MARK: - 두벌식 물리 키 → 호환 자모 매핑

    /// 시프트 없는 US 배열 글자 → 두벌식 자모.
    private static let unshifted: [Character: Character] = [
        "q": "ㅂ", "w": "ㅈ", "e": "ㄷ", "r": "ㄱ", "t": "ㅅ",
        "y": "ㅛ", "u": "ㅕ", "i": "ㅑ", "o": "ㅐ", "p": "ㅔ",
        "a": "ㅁ", "s": "ㄴ", "d": "ㅇ", "f": "ㄹ", "g": "ㅎ",
        "h": "ㅗ", "j": "ㅓ", "k": "ㅏ", "l": "ㅣ",
        "z": "ㅋ", "x": "ㅌ", "c": "ㅊ", "v": "ㅍ", "b": "ㅠ",
        "n": "ㅜ", "m": "ㅡ",
    ]

    /// 시프트가 '자모를 바꾸는' 글자만. 나머지 시프트 글자는 소문자 매핑을 따른다.
    private static let shifted: [Character: Character] = [
        "Q": "ㅃ", "W": "ㅉ", "E": "ㄸ", "R": "ㄲ", "T": "ㅆ",
        "O": "ㅒ", "P": "ㅖ",
    ]

    /// 물리 키 문자를 두벌식 자모(호환 자모)로. 자모 키가 아니면(`;`,숫자,공백,구두점) nil.
    public static func jamo(for physical: Character) -> Character? {
        if let s = shifted[physical] { return s }
        let lowerString = physical.lowercased()
        guard lowerString.count == 1, let lower = lowerString.first else { return nil }
        return unshifted[lower]
    }

    // MARK: - 자모 인덱스 테이블(유니코드 한글 조합 규칙)

    private static let choseong: [Character] = [
        "ㄱ", "ㄲ", "ㄴ", "ㄷ", "ㄸ", "ㄹ", "ㅁ", "ㅂ", "ㅃ", "ㅅ",
        "ㅆ", "ㅇ", "ㅈ", "ㅉ", "ㅊ", "ㅋ", "ㅌ", "ㅍ", "ㅎ",
    ]
    private static let jungseong: [Character] = [
        "ㅏ", "ㅐ", "ㅑ", "ㅒ", "ㅓ", "ㅔ", "ㅕ", "ㅖ", "ㅗ", "ㅘ",
        "ㅙ", "ㅚ", "ㅛ", "ㅜ", "ㅝ", "ㅞ", "ㅟ", "ㅠ", "ㅡ", "ㅢ", "ㅣ",
    ]

    private static let choIndex: [Character: Int] = Dictionary(
        uniqueKeysWithValues: choseong.enumerated().map { ($1, $0) })
    private static let jungIndex: [Character: Int] = Dictionary(
        uniqueKeysWithValues: jungseong.enumerated().map { ($1, $0) })

    /// 단일 자음 → 종성 인덱스(1...27). 종성이 될 수 없는 ㄸ/ㅃ/ㅉ은 빠져 있다.
    private static let simpleJong: [Character: Int] = [
        "ㄱ": 1, "ㄲ": 2, "ㄴ": 4, "ㄷ": 7, "ㄹ": 8, "ㅁ": 16, "ㅂ": 17, "ㅅ": 19,
        "ㅆ": 20, "ㅇ": 21, "ㅈ": 22, "ㅊ": 23, "ㅋ": 24, "ㅌ": 25, "ㅍ": 26, "ㅎ": 27,
    ]

    /// 겹모음 결합: (기존 중성 인덱스) → (더해지는 모음 → 결합 중성 인덱스).
    private static let compoundJung: [Int: [Character: Int]] = [
        8:  ["ㅏ": 9, "ㅐ": 10, "ㅣ": 11],   // ㅗ + ㅏ/ㅐ/ㅣ → ㅘ/ㅙ/ㅚ
        13: ["ㅓ": 14, "ㅔ": 15, "ㅣ": 16],  // ㅜ + ㅓ/ㅔ/ㅣ → ㅝ/ㅞ/ㅟ
        18: ["ㅣ": 19],                      // ㅡ + ㅣ → ㅢ
    ]

    /// 겹받침 결합: (기존 종성 인덱스) → (더해지는 자음 → 결합 종성 인덱스).
    private static let compoundJong: [Int: [Character: Int]] = [
        1:  ["ㅅ": 3],                       // ㄱ + ㅅ → ㄳ
        4:  ["ㅈ": 5, "ㅎ": 6],              // ㄴ + ㅈ/ㅎ → ㄵ/ㄶ
        8:  ["ㄱ": 9, "ㅁ": 10, "ㅂ": 11, "ㅅ": 12, "ㅌ": 13, "ㅍ": 14, "ㅎ": 15], // ㄹ + ...
        17: ["ㅅ": 18],                      // ㅂ + ㅅ → ㅄ
    ]

    /// 겹받침 분해(끝소리 빼앗기용): 종성 인덱스 → (남는 종성 인덱스, 빼앗겨 초성이 되는 자음).
    /// 단일 종성은 통째로(남는 종성 0) 초성이 되고, 겹받침은 앞 자음이 남고 뒤 자음이 초성이 된다.
    private static let jongDecompose: [Int: (remaining: Int, stolen: Character)] = [
        1: (0, "ㄱ"), 2: (0, "ㄲ"), 4: (0, "ㄴ"), 7: (0, "ㄷ"), 8: (0, "ㄹ"), 16: (0, "ㅁ"),
        17: (0, "ㅂ"), 19: (0, "ㅅ"), 20: (0, "ㅆ"), 21: (0, "ㅇ"), 22: (0, "ㅈ"), 23: (0, "ㅊ"),
        24: (0, "ㅋ"), 25: (0, "ㅌ"), 26: (0, "ㅍ"), 27: (0, "ㅎ"),
        3: (1, "ㅅ"), 5: (4, "ㅈ"), 6: (4, "ㅎ"), 9: (8, "ㄱ"), 10: (8, "ㅁ"), 11: (8, "ㅂ"),
        12: (8, "ㅅ"), 13: (8, "ㅌ"), 14: (8, "ㅍ"), 15: (8, "ㅎ"), 18: (17, "ㅅ"),
    ]

    // MARK: - 공개 API

    /// 물리 키 시퀀스가 화면에 만드는 문자열을 결정론적으로 재구성한다. 비-자모 키
    /// (`;`,숫자,공백,구두점)는 진행 중인 조합을 끊고 그 문자 그대로 한 글자를 이룬다.
    public static func compose(physicalKeys: [Character]) -> String {
        var automaton = Automaton()
        for key in physicalKeys { automaton.feed(key) }
        automaton.finish()
        return automaton.output
    }

    /// 물리 키 시퀀스가 화면에 만드는 '보이는 글자(grapheme)' 수.
    public static func glyphCount(physicalKeys: [Character]) -> Int {
        compose(physicalKeys: physicalKeys).count
    }

    // MARK: - 조합 오토마톤

    /// 진행 중인 한 음절(초성/중성/종성)을 들고, 규칙에 따라 확정(flush)하며 화면
    /// 문자열을 누적하는 상태 기계. 두벌식 실기 조합 순서를 그대로 흉내낸다.
    private struct Automaton {
        private(set) var output = ""
        private var cho: Int?
        private var jung: Int?
        private var jong: Int?  // 1...27, nil = 종성 없음

        private var isCurrentEmpty: Bool { cho == nil && jung == nil && jong == nil }

        /// 진행 중 음절을 화면 문자로 렌더링한다(확정하지 않는다).
        private func rendered() -> String {
            if let cho, let jung {
                let code = 0xAC00 + ((cho * 21) + jung) * 28 + (jong ?? 0)
                guard let scalar = Unicode.Scalar(code) else { return "" }
                return String(scalar)
            }
            if let cho { return String(choseong[cho]) }
            if let jung { return String(jungseong[jung]) }
            return ""
        }

        /// 진행 중 음절을 화면에 확정하고 상태를 비운다.
        private mutating func flush() {
            output += rendered()
            cho = nil
            jung = nil
            jong = nil
        }

        mutating func feed(_ key: Character) {
            guard let j = HangulComposer.jamo(for: key) else {
                // 비-자모: 진행 중 조합을 확정하고 그 글자를 그대로 한 글자로.
                flush()
                output.append(key)
                return
            }
            if let v = HangulComposer.jungIndex[j] {
                feedVowel(v)
            } else if let c = HangulComposer.choIndex[j] {
                feedConsonant(j, choIndexOf: c)
            } else {
                // 이론상 도달 불가(모든 자모는 초성이거나 중성).
                flush()
            }
        }

        mutating func finish() { flush() }

        private mutating func feedVowel(_ v: Int) {
            let vowel = HangulComposer.jungseong[v]

            // (1) 초성+중성 있고 종성 없음 → 겹모음 결합 시도.
            if cho != nil, let curJung = jung, jong == nil,
               let combined = HangulComposer.compoundJung[curJung]?[vowel] {
                jung = combined
                return
            }

            // (2) 끝소리 빼앗기: 종성이 있는 완성 음절 뒤에 모음 → 종성을 다음 음절 초성으로.
            if cho != nil, jung != nil, let curJong = jong {
                let decomposed = HangulComposer.jongDecompose[curJong] ?? (0, HangulComposer.choseong[0])
                jong = decomposed.remaining == 0 ? nil : decomposed.remaining
                output += rendered()  // 남은 종성까지만 붙인 음절을 확정.
                cho = HangulComposer.choIndex[decomposed.stolen]
                jung = v
                jong = nil
                return
            }

            // (3) 초성만 있고 중성 없음 → 중성 채우기.
            if cho != nil, jung == nil {
                jung = v
                return
            }

            // (4) 홑모음 진행 중 + 모음 → 겹모음 결합 시도(초성 없는 경우).
            if cho == nil, let curJung = jung, jong == nil,
               let combined = HangulComposer.compoundJung[curJung]?[vowel] {
                jung = combined
                return
            }

            // (5) 그 외 → 확정하고 홑모음으로 새 음절 시작.
            flush()
            jung = v
        }

        private mutating func feedConsonant(_ j: Character, choIndexOf c: Int) {
            // (1) 초성+중성 있고 종성 없음 → 종성으로(가능하면). 불가(ㄸㅃㅉ)면 새 음절.
            if cho != nil, jung != nil, jong == nil {
                if let ji = HangulComposer.simpleJong[j] {
                    jong = ji
                } else {
                    flush()
                    cho = c
                }
                return
            }

            // (2) 종성 있음 → 겹받침 결합 시도. 실패면 확정하고 새 음절.
            if let curJong = jong {
                if let combined = HangulComposer.compoundJong[curJong]?[j] {
                    jong = combined
                } else {
                    flush()
                    cho = c
                }
                return
            }

            // (3) 그 외(빈 상태·초성만·홑모음) → 확정하고 새 초성.
            flush()
            cho = c
        }
    }
}
