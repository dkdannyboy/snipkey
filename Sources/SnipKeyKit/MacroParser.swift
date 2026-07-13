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
///   %date:FORMAT%                                      date/time (DateFormatter pattern)
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
            for part in body.components(separatedBy: ":") {
                if part.hasPrefix("name=") {
                    name = String(part.dropFirst("name=".count))
                } else if part.hasPrefix("default=") {
                    defaultValue = String(part.dropFirst("default=".count))
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
        }
    }

    // MARK: - Fill-in fields

    public static func fillFields(in tokens: [MacroToken]) -> [FillField] {
        var fields: [FillField] = []
        var id = 0
        for token in tokens {
            switch token {
            case .fillText(let name, let def):
                fields.append(FillField(id: id, name: name, kind: .text, defaultValue: def))
                id += 1
            case .fillArea(let name, let def):
                fields.append(FillField(id: id, name: name, kind: .area, defaultValue: def))
                id += 1
            case .fillPopup(let name, let options, let def):
                fields.append(FillField(id: id, name: name, kind: .popup(options: options), defaultValue: def))
                id += 1
            case .fillPartStart(let name, let on):
                fields.append(FillField(id: id, name: name, kind: .part, defaultValue: on ? "yes" : "no"))
                id += 1
            default:
                break
            }
        }
        return fields
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
    public static func render(
        tokens: [MacroToken],
        fillValues: [Int: String] = [:],
        clipboard: @autoclosure () -> String = "",
        now: Date = Date()
    ) -> RenderResult {
        var out = ""
        var cursorPosition: Int? = nil // grapheme offset in `out`
        var trailingKeys: [String] = []
        var fieldID = 0
        var skippingPart = false

        for token in tokens {
            if case .fillPartEnd = token {
                skippingPart = false
                continue
            }
            if case .fillPartStart(_, let defaultOn) = token {
                let value = fillValues[fieldID] ?? (defaultOn ? "yes" : "no")
                skippingPart = value.lowercased() == "no"
                fieldID += 1
                continue
            }
            if skippingPart {
                // Fields inside a skipped part still consume their id.
                switch token {
                case .fillText, .fillArea, .fillPopup: fieldID += 1
                default: break
                }
                continue
            }
            switch token {
            case .text(let s):
                out += s
            case .fillText(_, let def), .fillArea(_, let def):
                out += fillValues[fieldID] ?? def
                fieldID += 1
            case .fillPopup(_, let options, let def):
                out += fillValues[fieldID] ?? (def.isEmpty ? (options.first ?? "") : def)
                fieldID += 1
            case .snippet(let abbrev):
                out += "%snippet:\(abbrev)%" // should have been resolved earlier
            case .clipboard:
                out += clipboard()
            case .key(let k):
                trailingKeys.append(k)
            case .cursor:
                cursorPosition = out.count
            case .date(let format):
                let formatter = DateFormatter()
                formatter.dateFormat = format
                out += formatter.string(from: now)
            case .fillPartStart, .fillPartEnd:
                break
            }
        }

        let offsetFromEnd = cursorPosition.map { out.count - $0 } ?? 0
        return RenderResult(text: out, cursorOffsetFromEnd: offsetFromEnd, trailingKeys: trailingKeys)
    }
}
