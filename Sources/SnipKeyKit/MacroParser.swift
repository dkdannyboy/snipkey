import Foundation

/// Parses TextExpander-compatible macros inside snippet content.
///
/// Supported syntax (verified against real TextExpander 5 data):
///   %filltext:name=X%  %filltext:name=X:default=Y%     single-line fill-in
///   %fillarea:name=X:default=Y%                        multi-line fill-in
///   %fillpopup:name=X:option one:option two:default=Y% popup fill-in
///   %fillpart:name=X:default=yes% ... %fillpartend%    optional section
///   %snippet:ABBREV%                                   nested snippet
///   %clipboard                                         current clipboard text
///   %key:enter%  %key:return%  %key:tab%               key press after expansion
///   %|                                                 cursor position
///   %date:FORMAT%  %date:+1d:FORMAT%                   date/time, optional date math
///   %Y %m %d %B %A … %@+1D                             TextExpander date codes (see DateMacro)
///
/// Unknown %-sequences (e.g. URL-encoded text like %EC%B0%A8) are left as-is.
public enum MacroToken: Equatable {
    case text(String)
    case fillText(name: String, defaultValue: String)
    case fillArea(name: String, defaultValue: String)
    case fillPopup(name: String, options: [String], defaultValue: String)
    case fillPartStart(name: String, defaultOn: Bool)
    case fillPartEnd
    case snippet(abbreviation: String)
    case clipboard
    case key(String)
    case cursor
    case date(format: String)
    /// TextExpander 날짜 코드 한 개(`Y`, `1m`, `B` …). 앞선 `%@±N단위` 이동이 적용된다.
    case textExpanderDate(code: String)
    /// TextExpander 날짜 이동 `%@+1D`. 뒤따르는 TextExpander 날짜 코드에 누적 적용된다.
    case dateShift(amount: Int, unit: Character)
}

/// A fill-in field presented to the user before expansion.
public struct FillField: Identifiable, Equatable {
    public enum Kind: Equatable {
        case text
        case area
        case popup(options: [String])
        case part // optional section toggle
    }
    public let id: Int
    public let name: String
    public let kind: Kind
    public let defaultValue: String

    public init(id: Int, name: String, kind: Kind, defaultValue: String) {
        self.id = id
        self.name = name
        self.kind = kind
        self.defaultValue = defaultValue
    }
}

public struct RenderResult: Equatable {
    public var text: String
    /// Number of characters (graphemes) after the cursor marker; 0 = cursor at end.
    public var cursorOffsetFromEnd: Int
    /// Key names (e.g. "enter") to press after inserting the text.
    public var trailingKeys: [String]
}

public enum MacroParser {

    // MARK: - Parsing

    public static func parse(_ content: String) -> [MacroToken] {
        var tokens: [MacroToken] = []
        var text = ""
        var i = content.startIndex

        func flushText() {
            if !text.isEmpty { tokens.append(.text(text)); text = "" }
        }

        while i < content.endIndex {
            guard content[i] == "%" else {
                text.append(content[i])
                i = content.index(after: i)
                continue
            }
            let rest = content[i...]
            if rest.hasPrefix("%|") {
                flushText()
                tokens.append(.cursor)
                i = content.index(i, offsetBy: 2)
                continue
            }
            if rest.hasPrefix("%clipboard") {
                flushText()
                tokens.append(.clipboard)
                i = content.index(i, offsetBy: "%clipboard".count)
                continue
            }
            if rest.hasPrefix("%fillpartend%") {
                flushText()
                tokens.append(.fillPartEnd)
                i = content.index(i, offsetBy: "%fillpartend%".count)
                continue
            }
            if let (token, consumed) = parseDelimitedMacro(rest) {
                flushText()
                tokens.append(token)
                i = content.index(i, offsetBy: consumed)
                continue
            }
            if let shift = DateMacro.textExpanderShift(at: rest) {
                flushText()
                tokens.append(.dateShift(amount: shift.amount, unit: shift.unit))
                i = content.index(i, offsetBy: shift.consumed)
                continue
            }
            if let code = DateMacro.textExpanderCode(at: rest) {
                flushText()
                tokens.append(.textExpanderDate(code: code.code))
                i = content.index(i, offsetBy: code.consumed)
                continue
            }
            // Not a recognized macro — keep the literal '%'.
            text.append(content[i])
            i = content.index(after: i)
        }
        flushText()
        return tokens
    }

    /// Parses macros of the form %keyword:body% and returns the token plus
    /// the number of characters consumed.
    private static func parseDelimitedMacro(_ rest: Substring) -> (MacroToken, Int)? {
        let keywords = ["filltext", "fillarea", "fillpopup", "fillpart", "snippet", "key", "date"]
        for keyword in keywords {
            let prefix = "%\(keyword):"
            guard rest.hasPrefix(prefix) else { continue }
            let bodyStart = rest.index(rest.startIndex, offsetBy: prefix.count)
            guard let end = rest[bodyStart...].firstIndex(of: "%") else { return nil }
            let body = String(rest[bodyStart..<end])
            let consumed = rest.distance(from: rest.startIndex, to: end) + 1
            guard let token = makeToken(keyword: keyword, body: body) else { return nil }
            return (token, consumed)
        }
        return nil
    }

    private static func makeToken(keyword: String, body: String) -> MacroToken? {
        switch keyword {
        case "snippet":
            return .snippet(abbreviation: body)
        case "key":
            return .key(body.lowercased())
        case "date":
            return .date(format: body)
        case "filltext", "fillarea", "fillpopup", "fillpart":
            var name = ""
            var defaultValue = ""
            var options: [String] = []
            // default= 값은 탐욕적으로 읽는다: default= 경계 이후 본문 끝까지(콜론 포함) 전부가
            // 기본값이다. URL의 "https://", 시각의 "10:30"처럼 값에 든 ':'가 살아남아야 하기
            // 때문 — 예전처럼 본문 전체를 ':'로 쪼개면 그 콜론들이 옵션으로 잘려 나가 값이
            // 조용히 깨진다. 이름·옵션·width/height는 default= '앞부분'에서만 ':'로 쪼갠다.
            // '앞부분'에는 default=가 없으므로 기존 콘텐츠(콜론 없는 기본값)는 동일하게 파싱된다.
            let beforeDefault: String
            if let clause = rangeOfDefaultClause(in: body) {
                defaultValue = String(body[clause.upperBound...])
                beforeDefault = String(body[..<clause.lowerBound])
            } else {
                beforeDefault = body
            }
            for part in beforeDefault.components(separatedBy: ":") {
                if part.hasPrefix("name=") {
                    name = String(part.dropFirst("name=".count))
                } else if part.hasPrefix("width=") || part.hasPrefix("height=") {
                    continue // layout hints — ignored
                } else if !part.isEmpty {
                    options.append(part)
                }
            }
            switch keyword {
            case "filltext": return .fillText(name: name, defaultValue: defaultValue)
            case "fillarea": return .fillArea(name: name, defaultValue: defaultValue)
            case "fillpopup": return .fillPopup(name: name, options: options, defaultValue: defaultValue)
            case "fillpart":
                let on = defaultValue.lowercased() != "no"
                return .fillPartStart(name: name, defaultOn: on)
            default: return nil
            }
        default:
            return nil
        }
    }

    /// 채우기 본문에서 default= 절의 위치를 찾는다. 반환 범위의 lowerBound는 절 앞의
    /// 경계(':' 또는 본문 시작)이고 upperBound는 "default=" 바로 뒤다. 그래서 lowerBound
    /// 앞은 이름/옵션으로, upperBound 뒤 전체는 (콜론을 포함해) 기본값으로 나뉜다.
    /// 첫 번째 default=만 절로 인정한다 — 뒤에 또 나오는 "default="는 값의 일부로 본다.
    private static func rangeOfDefaultClause(in body: String) -> Range<String.Index>? {
        let token = "default="
        // 이름 없이 본문이 곧장 default=로 시작하는 경우(예: "default=foo").
        if body.hasPrefix(token) {
            return body.startIndex..<body.index(body.startIndex, offsetBy: token.count)
        }
        // 일반적인 경우: 파트 경계인 ':' 뒤에 default=가 온다.
        return body.range(of: ":" + token)
    }

    // MARK: - Nested snippets

    /// Replaces %snippet:ABBREV% tokens with the referenced snippet content,
    /// recursively, before any other processing.
    public static func resolveNested(
        _ content: String,
        lookup: (String) -> String?,
        depth: Int = 0
    ) -> String {
        guard depth < 10, content.contains("%snippet:") else { return content }
        var result = ""
        for token in parse(content) {
            switch token {
            case .snippet(let abbrev):
                if let nested = lookup(abbrev) {
                    result += resolveNested(nested, lookup: lookup, depth: depth + 1)
                } else {
                    result += "%snippet:\(abbrev)%" // unresolved — keep literal
                }
            default:
                result += literal(of: token)
            }
        }
        return result
    }

    /// Reconstructs the literal source text of a token (used when re-emitting).
    private static func literal(of token: MacroToken) -> String {
        switch token {
        case .text(let s): return s
        case .fillText(let n, let d): return d.isEmpty ? "%filltext:name=\(n)%" : "%filltext:name=\(n):default=\(d)%"
        case .fillArea(let n, let d): return d.isEmpty ? "%fillarea:name=\(n)%" : "%fillarea:name=\(n):default=\(d)%"
        case .fillPopup(let n, let opts, let d):
            var body = "name=\(n)"
            for o in opts { body += ":\(o)" }
            if !d.isEmpty { body += ":default=\(d)" }
            return "%fillpopup:\(body)%"
        case .fillPartStart(let n, let on): return "%fillpart:name=\(n):default=\(on ? "yes" : "no")%"
        case .fillPartEnd: return "%fillpartend%"
        case .snippet(let a): return "%snippet:\(a)%"
        case .clipboard: return "%clipboard"
        case .key(let k): return "%key:\(k)%"
        case .cursor: return "%|"
        case .date(let f): return "%date:\(f)%"
        case .textExpanderDate(let code): return "%" + code
        case .dateShift(let amount, let unit): return "%@\(amount < 0 ? "-" : "+")\(abs(amount))\(unit)"
        }
    }

    // MARK: - Fill-in fields

    /// 토큰마다 필드 번호를 매긴다(필드가 아닌 토큰은 nil). `fillFields`와 `render`가
    /// **반드시** 같은 번호를 쓰도록 번호 매기기를 이 한 곳에 둔다.
    ///
    /// 이름이 같은 필드는 번호를 공유한다 — TextExpander처럼 `%filltext:name=고객%`이
    /// 두 번 나와도 한 번만 묻고, 두 자리 모두 같은 값으로 채운다. 값 필드(text·area·
    /// popup)와 구간 토글(part)은 서로 다른 이름 공간이다. 이름이 빈 필드는 공유하지
    /// 않는다 — 이름 없는 필드 둘은 서로 다른 질문이다.
    static func fieldAssignments(_ tokens: [MacroToken]) -> (ids: [Int?], fields: [FillField]) {
        var ids: [Int?] = []
        var fields: [FillField] = []
        var byKey: [String: Int] = [:]

        func assign(_ key: String?, _ make: (Int) -> FillField) -> Int {
            if let key, let existing = byKey[key] { return existing }
            let id = fields.count
            fields.append(make(id))
            if let key { byKey[key] = id }
            return id
        }

        for token in tokens {
            switch token {
            case .fillText(let name, let def):
                ids.append(assign(name.isEmpty ? nil : "v|" + name) {
                    FillField(id: $0, name: name, kind: .text, defaultValue: def)
                })
            case .fillArea(let name, let def):
                ids.append(assign(name.isEmpty ? nil : "v|" + name) {
                    FillField(id: $0, name: name, kind: .area, defaultValue: def)
                })
            case .fillPopup(let name, let options, let def):
                ids.append(assign(name.isEmpty ? nil : "v|" + name) {
                    FillField(id: $0, name: name, kind: .popup(options: options), defaultValue: def)
                })
            case .fillPartStart(let name, let on):
                ids.append(assign(name.isEmpty ? nil : "p|" + name) {
                    FillField(id: $0, name: name, kind: .part, defaultValue: on ? "yes" : "no")
                })
            default:
                ids.append(nil)
            }
        }
        return (ids, fields)
    }

    public static func fillFields(in tokens: [MacroToken]) -> [FillField] {
        fieldAssignments(tokens).fields
    }

    public static func hasFillIns(_ tokens: [MacroToken]) -> Bool {
        tokens.contains { token in
            switch token {
            case .fillText, .fillArea, .fillPopup, .fillPartStart: return true
            default: return false
            }
        }
    }

    // MARK: - Rendering

    /// Produces the final text. `fillValues` maps FillField.id to the value
    /// entered by the user ("yes"/"no" for part toggles).
    ///
    /// 선택 구간은 스택으로 추적한다: 바깥 구간이 꺼져 있으면 안쪽은 설정과 무관하게
    /// 꺼진다. 끝 표시(`%fillpartend%`)가 없는 꺼진 구간은 뒤를 통째로 삼키는 대신
    /// 포함한다 — 편집기 미리보기(`MacroPreview`)와 같은 규칙이어야 사용자가 본 것과
    /// 실제로 나가는 것이 같다.
    public static func render(
        tokens: [MacroToken],
        fillValues: [Int: String] = [:],
        clipboard: @autoclosure () -> String = "",
        now: Date = Date(),
        timeZone: TimeZone = .current,
        locale: Locale = .current
    ) -> RenderResult {
        var out = ""
        var cursorPosition: Int? = nil // grapheme offset in `out`
        var trailingKeys: [String] = []
        let ids = fieldAssignments(tokens).ids
        // 각 원소는 "이 구간 안에서 출력하는가". 맨 위가 현재 상태다.
        var partStack: [Bool] = []
        // TextExpander의 `%@+1D`는 뒤따르는 날짜 코드 전부에 누적 적용된다.
        var shiftedNow = now
        let calendar = DateMacro.calendar(timeZone)
        var emitting: Bool { partStack.last ?? true }

        func value(at index: Int, fallback: String) -> String {
            guard let id = ids[index] else { return fallback }
            return fillValues[id] ?? fallback
        }

        for (index, token) in tokens.enumerated() {
            if case .fillPartEnd = token {
                if !partStack.isEmpty { partStack.removeLast() }
                continue
            }
            if case .fillPartStart(_, let defaultOn) = token {
                let on = value(at: index, fallback: defaultOn ? "yes" : "no").lowercased() != "no"
                let closed = hasMatchingEnd(after: index, in: tokens)
                partStack.append(emitting && (on || !closed))
                continue
            }
            guard emitting else { continue }
            switch token {
            case .text(let s):
                out += s
            case .fillText(_, let def), .fillArea(_, let def):
                out += value(at: index, fallback: def)
            case .fillPopup(_, let options, let def):
                out += value(at: index, fallback: def.isEmpty ? (options.first ?? "") : def)
            case .snippet(let abbrev):
                out += "%snippet:\(abbrev)%" // should have been resolved earlier
            case .clipboard:
                out += clipboard()
            case .key(let k):
                trailingKeys.append(k)
            case .cursor:
                cursorPosition = out.count
            case .date(let body):
                out += DateMacro.string(body: body, now: now, timeZone: timeZone, locale: locale)
            case .textExpanderDate(let code):
                out += DateMacro.string(textExpanderCode: code, date: shiftedNow, timeZone: timeZone, locale: locale)
            case .dateShift(let amount, let unit):
                shiftedNow = DateMacro.shift(shiftedNow, by: amount, unit: unit, calendar: calendar)
            case .fillPartStart, .fillPartEnd:
                break
            }
        }

        let offsetFromEnd = cursorPosition.map { out.count - $0 } ?? 0
        return RenderResult(text: out, cursorOffsetFromEnd: offsetFromEnd, trailingKeys: trailingKeys)
    }

    /// `start`의 구간 시작과 짝이 되는 끝 표시가 있는가(중첩 깊이를 센다).
    private static func hasMatchingEnd(after start: Int, in tokens: [MacroToken]) -> Bool {
        var depth = 1
        for token in tokens[(start + 1)...] {
            switch token {
            case .fillPartStart: depth += 1
            case .fillPartEnd:
                depth -= 1
                if depth == 0 { return true }
            default: break
            }
        }
        return false
    }
}
