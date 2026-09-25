import Foundation

/// 날짜 매크로의 해석 규칙. 실제 확장(`MacroParser.render`)과 미리보기(`MacroPreview`)가
/// 이 한 곳을 공유해야 편집기에서 본 날짜와 실제로 나가는 날짜가 같다.
///
/// 두 문법을 지원한다.
///   `%date:FORMAT%`, `%date:+1d:FORMAT%`  — SnipKey 문법. 선택적 날짜 계산 접두어.
///   `%Y` `%m` `%d` … `%@+1D`              — TextExpander 날짜 코드. 가져온 스니펫이 그대로 동작하게.
public enum DateMacro {

    // MARK: - 날짜 계산

    /// 날짜 계산 단위. 대소문자가 뜻을 가른다: `m`은 분, `M`은 월 — DateFormatter의
    /// `mm`/`MM`과 같은 관례라 사용자가 한 번 익히면 헷갈리지 않는다.
    static func component(forUnit unit: Character) -> (Calendar.Component, Int)? {
        switch unit {
        case "s": return (.second, 1)
        case "m": return (.minute, 1)
        case "h", "H": return (.hour, 1)
        case "d", "D": return (.day, 1)
        case "w", "W": return (.day, 7)
        case "M": return (.month, 1)
        case "y", "Y": return (.year, 1)
        default: return nil
        }
    }

    static func shift(_ date: Date, by amount: Int, unit: Character, calendar: Calendar) -> Date {
        guard let (component, multiplier) = component(forUnit: unit) else { return date }
        return calendar.date(byAdding: component, value: amount * multiplier, to: date) ?? date
    }

    /// `+1d:yyyy-MM-dd` → (+1, "d", "yyyy-MM-dd"). 계산 접두어가 없으면 nil —
    /// 그때는 본문 전체가 포맷이다(기존 동작 그대로).
    static func splitOffset(_ body: String) -> (amount: Int, unit: Character, format: String)? {
        guard let first = body.first, first == "+" || first == "-" else { return nil }
        let chars = Array(body)
        var i = 1
        while i < chars.count, chars[i].isASCII, chars[i].isNumber { i += 1 }
        guard i > 1, i + 1 < chars.count, chars[i + 1] == ":",
              component(forUnit: chars[i]) != nil,
              let magnitude = Int(String(chars[1..<i]))
        else { return nil }
        let format = String(chars[(i + 2)...])
        return (first == "-" ? -magnitude : magnitude, chars[i], format)
    }

    /// `%date:BODY%`의 결과 문자열.
    public static func string(
        body: String,
        now: Date,
        timeZone: TimeZone = .current,
        locale: Locale = .current
    ) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        var date = now
        var format = body
        if let (amount, unit, rest) = splitOffset(body) {
            date = shift(now, by: amount, unit: unit, calendar: calendar)
            format = rest
        }
        return formatter(format, timeZone: timeZone, locale: locale).string(from: date)
    }

    // MARK: - TextExpander 날짜 코드

    /// TextExpander 코드 → DateFormatter 패턴. 두 글자 코드(`1m`)를 먼저 본다.
    static let textExpanderCodes: [(code: String, pattern: String)] = [
        ("1m", "M"), ("1H", "H"), ("1I", "h"),
        ("Y", "yyyy"), ("y", "yy"),
        ("m", "MM"), ("B", "MMMM"), ("b", "MMM"),
        ("d", "dd"), ("e", "d"),
        ("A", "EEEE"), ("a", "EEE"),
        ("H", "HH"), ("I", "hh"), ("M", "mm"), ("S", "ss"), ("p", "a"),
    ]

    /// `rest`가 '%'로 시작하는 TextExpander 날짜 코드면 (코드, 소비한 글자 수).
    ///
    /// 스니펫에는 퍼센트 인코딩된 URL(`%EB%AF%B8`)과 평범한 문장(`50%discount`)이 섞여
    /// 있으므로 두 가지 보호 규칙을 둔다. 둘 중 하나라도 걸리면 코드가 아니라 글자다.
    ///   1) '%' 뒤 두 글자가 모두 16진수 → 퍼센트 인코딩이다.
    ///   2) 코드 바로 뒤에 영문자가 온다 → 단어의 일부다.
    static func textExpanderCode(at rest: Substring) -> (code: String, consumed: Int)? {
        let after = rest.dropFirst()
        let firstTwo = after.prefix(2)
        if firstTwo.count == 2, firstTwo.allSatisfy(\.isHexDigit) { return nil }
        for (code, _) in textExpanderCodes where after.hasPrefix(code) {
            if let next = after.dropFirst(code.count).first, next.isASCII, next.isLetter {
                return nil
            }
            return (code, code.count + 1)
        }
        return nil
    }

    /// `%@+1D` 형태의 TextExpander 날짜 이동. 뒤따르는 날짜 코드에 적용된다.
    static func textExpanderShift(at rest: Substring) -> (amount: Int, unit: Character, consumed: Int)? {
        guard rest.hasPrefix("%@") else { return nil }
        let chars = Array(rest.dropFirst(2))
        guard let sign = chars.first, sign == "+" || sign == "-" else { return nil }
        var i = 1
        while i < chars.count, chars[i].isASCII, chars[i].isNumber { i += 1 }
        guard i > 1, i < chars.count, component(forUnit: chars[i]) != nil,
              let magnitude = Int(String(chars[1..<i]))
        else { return nil }
        return (sign == "-" ? -magnitude : magnitude, chars[i], 2 + i + 1)
    }

    public static func string(
        textExpanderCode code: String,
        date: Date,
        timeZone: TimeZone = .current,
        locale: Locale = .current
    ) -> String {
        guard let pattern = textExpanderCodes.first(where: { $0.code == code })?.pattern else { return "%" + code }
        return formatter(pattern, timeZone: timeZone, locale: locale).string(from: date)
    }

    static func calendar(_ timeZone: TimeZone) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar
    }

    private static func formatter(_ format: String, timeZone: TimeZone, locale: Locale) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = timeZone
        formatter.dateFormat = format
        return formatter
    }
}
