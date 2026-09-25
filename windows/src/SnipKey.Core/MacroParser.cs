using System.Globalization;
using System.Text;

namespace SnipKey.Core;

// macOS 판 MacroParser.swift 의 이식. 같은 스니펫이 두 OS 에서 같은 결과를 내야 하므로
// 규칙(탐욕적 default=, 중첩 선택 구간 스택, 같은 이름 필드 공유)을 그대로 옮긴다.

public abstract record MacroToken
{
    public sealed record Text(string Value) : MacroToken;
    public sealed record FillText(string Name, string DefaultValue) : MacroToken;
    public sealed record FillArea(string Name, string DefaultValue) : MacroToken;
    public sealed record FillPopup(string Name, IReadOnlyList<string> Options, string DefaultValue) : MacroToken
    {
        public bool Equals(FillPopup? other) =>
            other is not null && Name == other.Name && DefaultValue == other.DefaultValue && Options.SequenceEqual(other.Options);
        public override int GetHashCode() => HashCode.Combine(Name, DefaultValue, Options.Count);
    }
    public sealed record FillPartStart(string Name, bool DefaultOn) : MacroToken;
    public sealed record FillPartEnd : MacroToken;
    public sealed record SnippetRef(string Abbreviation) : MacroToken;
    public sealed record Clipboard : MacroToken;
    public sealed record Key(string Name) : MacroToken;
    public sealed record Cursor : MacroToken;
    public sealed record Date(string Format) : MacroToken;
    public sealed record TextExpanderDate(string Code) : MacroToken;
    public sealed record DateShift(int Amount, char Unit) : MacroToken;
}

public enum FillKind { Text, Area, Popup, Part }

public sealed record FillField(int Id, string Name, FillKind Kind, string DefaultValue, IReadOnlyList<string> Options);

public sealed record RenderResult(string Text, int CursorOffsetFromEnd, IReadOnlyList<string> TrailingKeys);

public static class MacroParser
{
    private static readonly string[] DelimitedKeywords = { "filltext", "fillarea", "fillpopup", "fillpart", "snippet", "key", "date" };

    public static List<MacroToken> Parse(string content)
    {
        var tokens = new List<MacroToken>();
        var text = new StringBuilder();
        void Flush()
        {
            if (text.Length > 0) { tokens.Add(new MacroToken.Text(text.ToString())); text.Clear(); }
        }

        var i = 0;
        while (i < content.Length)
        {
            if (content[i] != '%') { text.Append(content[i]); i++; continue; }

            if (At(content, i, "%|")) { Flush(); tokens.Add(new MacroToken.Cursor()); i += 2; continue; }
            if (At(content, i, "%clipboard")) { Flush(); tokens.Add(new MacroToken.Clipboard()); i += "%clipboard".Length; continue; }
            if (At(content, i, "%fillpartend%")) { Flush(); tokens.Add(new MacroToken.FillPartEnd()); i += "%fillpartend%".Length; continue; }
            if (ParseDelimited(content, i) is { } delimited)
            {
                Flush(); tokens.Add(delimited.Token); i += delimited.Consumed; continue;
            }
            if (DateMacro.TextExpanderShift(content, i) is { } shift)
            {
                Flush(); tokens.Add(new MacroToken.DateShift(shift.Amount, shift.Unit)); i += shift.Consumed; continue;
            }
            if (DateMacro.TextExpanderCode(content, i) is { } code)
            {
                Flush(); tokens.Add(new MacroToken.TextExpanderDate(code.Code)); i += code.Consumed; continue;
            }
            // 알 수 없는 '%'(퍼센트 인코딩 URL 등)는 글자 그대로 둔다.
            text.Append('%');
            i++;
        }
        Flush();
        return tokens;
    }

    private static bool At(string s, int i, string prefix) => string.CompareOrdinal(s, i, prefix, 0, prefix.Length) == 0;

    private static (MacroToken Token, int Consumed)? ParseDelimited(string s, int at)
    {
        foreach (var keyword in DelimitedKeywords)
        {
            var prefix = "%" + keyword + ":";
            if (!At(s, at, prefix)) continue;
            var bodyStart = at + prefix.Length;
            var end = s.IndexOf('%', bodyStart);
            if (end < 0) return null;
            var token = MakeToken(keyword, s[bodyStart..end]);
            return token is null ? null : (token, end - at + 1);
        }
        return null;
    }

    private static MacroToken? MakeToken(string keyword, string body)
    {
        switch (keyword)
        {
            case "snippet": return new MacroToken.SnippetRef(body);
            case "key": return new MacroToken.Key(body.ToLowerInvariant());
            case "date": return new MacroToken.Date(body);
        }

        // default= 는 탐욕적으로: 첫 default= 뒤 전체(콜론 포함)가 기본값이다.
        string beforeDefault, defaultValue = "";
        var clause = DefaultClause(body);
        if (clause is { } c)
        {
            defaultValue = body[c.ValueStart..];
            beforeDefault = body[..c.Start];
        }
        else beforeDefault = body;

        var name = "";
        var options = new List<string>();
        foreach (var part in beforeDefault.Split(':'))
        {
            if (part.StartsWith("name=", StringComparison.Ordinal)) name = part["name=".Length..];
            else if (part.StartsWith("width=", StringComparison.Ordinal) || part.StartsWith("height=", StringComparison.Ordinal)) continue;
            else if (part.Length > 0) options.Add(part);
        }

        return keyword switch
        {
            "filltext" => new MacroToken.FillText(name, defaultValue),
            "fillarea" => new MacroToken.FillArea(name, defaultValue),
            "fillpopup" => new MacroToken.FillPopup(name, options, defaultValue),
            "fillpart" => new MacroToken.FillPartStart(name, !defaultValue.Equals("no", StringComparison.OrdinalIgnoreCase)),
            _ => null,
        };
    }

    private static (int Start, int ValueStart)? DefaultClause(string body)
    {
        const string token = "default=";
        if (body.StartsWith(token, StringComparison.Ordinal)) return (0, token.Length);
        var idx = body.IndexOf(":" + token, StringComparison.Ordinal);
        return idx < 0 ? null : (idx, idx + 1 + token.Length);
    }

    // ---- 중첩 스니펫 ----

    public static string ResolveNested(string content, Func<string, string?> lookup, int depth = 0)
    {
        if (depth >= 10 || !content.Contains("%snippet:", StringComparison.Ordinal)) return content;
        var sb = new StringBuilder();
        foreach (var token in Parse(content))
        {
            if (token is MacroToken.SnippetRef r)
            {
                var nested = lookup(r.Abbreviation);
                sb.Append(nested is null ? $"%snippet:{r.Abbreviation}%" : ResolveNested(nested, lookup, depth + 1));
            }
            else sb.Append(Literal(token));
        }
        return sb.ToString();
    }

    public static string Literal(MacroToken token) => token switch
    {
        MacroToken.Text t => t.Value,
        MacroToken.FillText f => f.DefaultValue.Length == 0 ? $"%filltext:name={f.Name}%" : $"%filltext:name={f.Name}:default={f.DefaultValue}%",
        MacroToken.FillArea f => f.DefaultValue.Length == 0 ? $"%fillarea:name={f.Name}%" : $"%fillarea:name={f.Name}:default={f.DefaultValue}%",
        MacroToken.FillPopup p => "%fillpopup:name=" + p.Name + string.Concat(p.Options.Select(o => ":" + o))
                                  + (p.DefaultValue.Length == 0 ? "" : ":default=" + p.DefaultValue) + "%",
        MacroToken.FillPartStart p => $"%fillpart:name={p.Name}:default={(p.DefaultOn ? "yes" : "no")}%",
        MacroToken.FillPartEnd => "%fillpartend%",
        MacroToken.SnippetRef r => $"%snippet:{r.Abbreviation}%",
        MacroToken.Clipboard => "%clipboard",
        MacroToken.Key k => $"%key:{k.Name}%",
        MacroToken.Cursor => "%|",
        MacroToken.Date d => $"%date:{d.Format}%",
        MacroToken.TextExpanderDate d => "%" + d.Code,
        MacroToken.DateShift s => $"%@{(s.Amount < 0 ? "-" : "+")}{Math.Abs(s.Amount)}{s.Unit}",
        _ => "",
    };

    // ---- 채우기 필드 ----

    /// <summary>토큰마다 필드 번호(필드가 아니면 null). 이름이 같은 필드는 번호를 공유한다.</summary>
    public static (int?[] Ids, List<FillField> Fields) FieldAssignments(IReadOnlyList<MacroToken> tokens)
    {
        var ids = new int?[tokens.Count];
        var fields = new List<FillField>();
        var byKey = new Dictionary<string, int>(StringComparer.Ordinal);

        int Assign(string? key, Func<int, FillField> make)
        {
            if (key is not null && byKey.TryGetValue(key, out var existing)) return existing;
            var id = fields.Count;
            fields.Add(make(id));
            if (key is not null) byKey[key] = id;
            return id;
        }

        static string? Key(string ns, string name) => name.Length == 0 ? null : ns + "|" + name;

        for (var i = 0; i < tokens.Count; i++)
        {
            ids[i] = tokens[i] switch
            {
                MacroToken.FillText f => Assign(Key("v", f.Name), id => new FillField(id, f.Name, FillKind.Text, f.DefaultValue, Array.Empty<string>())),
                MacroToken.FillArea f => Assign(Key("v", f.Name), id => new FillField(id, f.Name, FillKind.Area, f.DefaultValue, Array.Empty<string>())),
                MacroToken.FillPopup p => Assign(Key("v", p.Name), id => new FillField(id, p.Name, FillKind.Popup, p.DefaultValue, p.Options)),
                MacroToken.FillPartStart p => Assign(Key("p", p.Name), id => new FillField(id, p.Name, FillKind.Part, p.DefaultOn ? "yes" : "no", Array.Empty<string>())),
                _ => null,
            };
        }
        return (ids, fields);
    }

    public static List<FillField> FillFields(IReadOnlyList<MacroToken> tokens) => FieldAssignments(tokens).Fields;

    public static bool HasFillIns(IReadOnlyList<MacroToken> tokens) =>
        tokens.Any(t => t is MacroToken.FillText or MacroToken.FillArea or MacroToken.FillPopup or MacroToken.FillPartStart);

    // ---- 렌더링 ----

    /// <param name="now">사용자 시간대의 현재 시각.</param>
    public static RenderResult Render(
        IReadOnlyList<MacroToken> tokens,
        IReadOnlyDictionary<int, string>? fillValues = null,
        Func<string>? clipboard = null,
        DateTime? now = null,
        CultureInfo? culture = null)
    {
        fillValues ??= new Dictionary<int, string>();
        var nowValue = now ?? DateTime.Now;
        var shiftedNow = nowValue;
        culture ??= CultureInfo.CurrentCulture;

        var ids = FieldAssignments(tokens).Ids;
        var outText = new StringBuilder();
        int? cursorPosition = null; // 글자(텍스트 요소) 기준
        var trailingKeys = new List<string>();
        var partStack = new Stack<bool>();
        bool Emitting() => partStack.Count == 0 || partStack.Peek();

        string Value(int index, string fallback) =>
            ids[index] is { } id && fillValues.TryGetValue(id, out var v) ? v : fallback;

        for (var i = 0; i < tokens.Count; i++)
        {
            var token = tokens[i];
            if (token is MacroToken.FillPartEnd)
            {
                if (partStack.Count > 0) partStack.Pop();
                continue;
            }
            if (token is MacroToken.FillPartStart start)
            {
                var on = !Value(i, start.DefaultOn ? "yes" : "no").Equals("no", StringComparison.OrdinalIgnoreCase);
                partStack.Push(Emitting() && (on || !HasMatchingEnd(tokens, i)));
                continue;
            }
            if (!Emitting()) continue;

            switch (token)
            {
                case MacroToken.Text t: outText.Append(t.Value); break;
                case MacroToken.FillText f: outText.Append(Value(i, f.DefaultValue)); break;
                case MacroToken.FillArea f: outText.Append(Value(i, f.DefaultValue)); break;
                case MacroToken.FillPopup p:
                    outText.Append(Value(i, p.DefaultValue.Length > 0 ? p.DefaultValue : p.Options.FirstOrDefault() ?? ""));
                    break;
                case MacroToken.SnippetRef r: outText.Append($"%snippet:{r.Abbreviation}%"); break;
                case MacroToken.Clipboard: outText.Append(clipboard?.Invoke() ?? ""); break;
                case MacroToken.Key k: trailingKeys.Add(k.Name); break;
                case MacroToken.Cursor: cursorPosition = TextElements.Count(outText.ToString()); break;
                case MacroToken.Date d: outText.Append(DateMacro.Format(d.Format, nowValue, culture)); break;
                case MacroToken.TextExpanderDate d: outText.Append(DateMacro.FormatTextExpanderCode(d.Code, shiftedNow, culture)); break;
                case MacroToken.DateShift s: shiftedNow = DateMacro.Shift(shiftedNow, s.Amount, s.Unit); break;
            }
        }

        var text = outText.ToString();
        var offset = cursorPosition is { } pos ? TextElements.Count(text) - pos : 0;
        return new RenderResult(text, offset, trailingKeys);
    }

    private static bool HasMatchingEnd(IReadOnlyList<MacroToken> tokens, int start)
    {
        var depth = 1;
        for (var j = start + 1; j < tokens.Count; j++)
        {
            if (tokens[j] is MacroToken.FillPartStart) depth++;
            else if (tokens[j] is MacroToken.FillPartEnd && --depth == 0) return true;
        }
        return false;
    }
}

/// <summary>Swift 의 Character(확장 자소 클러스터) 단위 셈. 백스페이스 수와 커서 이동이 이 단위다.</summary>
public static class TextElements
{
    public static int Count(string s) => new StringInfo(s).LengthInTextElements;

    public static List<string> Split(string s)
    {
        var list = new List<string>();
        var e = StringInfo.GetTextElementEnumerator(s);
        while (e.MoveNext()) list.Add((string)e.Current);
        return list;
    }
}
