using System.Globalization;
using System.Text;

namespace SnipKey.Core;

/// <summary>
/// macOS 판 DateMacro.swift 의 이식. 날짜 계산(<c>%date:+1d:yyyy-MM-dd%</c>)과
/// TextExpander 날짜 코드(<c>%Y</c>, <c>%B</c>, <c>%@+1D</c> …).
/// </summary>
public static class DateMacro
{
    /// <summary>대소문자가 뜻을 가른다: m = 분, M = 월 (날짜 패턴의 mm/MM 관례).</summary>
    public static bool IsUnit(char unit) => unit is 's' or 'm' or 'h' or 'H' or 'd' or 'D' or 'w' or 'W' or 'M' or 'y' or 'Y';

    public static DateTime Shift(DateTime date, int amount, char unit) => unit switch
    {
        's' => date.AddSeconds(amount),
        'm' => date.AddMinutes(amount),
        'h' or 'H' => date.AddHours(amount),
        'd' or 'D' => date.AddDays(amount),
        'w' or 'W' => date.AddDays(7 * amount),
        'M' => date.AddMonths(amount),
        'y' or 'Y' => date.AddYears(amount),
        _ => date,
    };

    /// <summary><c>+1d:yyyy-MM-dd</c> → (1, 'd', "yyyy-MM-dd"). 계산 접두어가 없으면 null.</summary>
    public static (int Amount, char Unit, string Format)? SplitOffset(string body)
    {
        if (body.Length == 0 || (body[0] != '+' && body[0] != '-')) return null;
        var i = 1;
        while (i < body.Length && char.IsAsciiDigit(body[i])) i++;
        if (i == 1 || i + 1 >= body.Length || body[i + 1] != ':' || !IsUnit(body[i])) return null;
        if (!int.TryParse(body.AsSpan(1, i - 1), NumberStyles.None, CultureInfo.InvariantCulture, out var magnitude)) return null;
        return (body[0] == '-' ? -magnitude : magnitude, body[i], body[(i + 2)..]);
    }

    /// <summary><c>%date:BODY%</c> 의 결과. <paramref name="now"/> 는 이미 사용자 시간대의 시각이다.</summary>
    public static string Format(string body, DateTime now, CultureInfo culture)
    {
        var date = now;
        var format = body;
        if (SplitOffset(body) is { } offset)
        {
            date = Shift(now, offset.Amount, offset.Unit);
            format = offset.Format;
        }
        return date.ToString(DatePattern.ToDotNet(format), culture);
    }

    // TextExpander 코드 → Unicode 날짜 패턴. 두 글자 코드(1m)를 먼저 본다.
    internal static readonly (string Code, string Pattern)[] TextExpanderCodes =
    {
        ("1m", "M"), ("1H", "H"), ("1I", "h"),
        ("Y", "yyyy"), ("y", "yy"),
        ("m", "MM"), ("B", "MMMM"), ("b", "MMM"),
        ("d", "dd"), ("e", "d"),
        ("A", "EEEE"), ("a", "EEE"),
        ("H", "HH"), ("I", "hh"), ("M", "mm"), ("S", "ss"), ("p", "a"),
    };

    /// <summary>
    /// <paramref name="s"/>[<paramref name="at"/>] 의 '%' 가 TextExpander 날짜 코드면 (코드, 소비 길이).
    /// 퍼센트 인코딩(<c>%EB%AF</c>)과 단어(<c>50%discount</c>)를 보호하는 두 규칙이 있다.
    /// </summary>
    public static (string Code, int Consumed)? TextExpanderCode(string s, int at)
    {
        var after = at + 1;
        if (after + 1 < s.Length && char.IsAsciiHexDigit(s[after]) && char.IsAsciiHexDigit(s[after + 1])) return null;
        foreach (var (code, _) in TextExpanderCodes)
        {
            if (string.CompareOrdinal(s, after, code, 0, code.Length) != 0) continue;
            var next = after + code.Length;
            if (next < s.Length && char.IsAsciiLetter(s[next])) return null;
            return (code, code.Length + 1);
        }
        return null;
    }

    /// <summary><c>%@+1D</c> 형태의 날짜 이동.</summary>
    public static (int Amount, char Unit, int Consumed)? TextExpanderShift(string s, int at)
    {
        if (at + 2 >= s.Length || s[at + 1] != '@') return null;
        var sign = s[at + 2];
        if (sign != '+' && sign != '-') return null;
        var i = at + 3;
        while (i < s.Length && char.IsAsciiDigit(s[i])) i++;
        if (i == at + 3 || i >= s.Length || !IsUnit(s[i])) return null;
        if (!int.TryParse(s.AsSpan(at + 3, i - at - 3), NumberStyles.None, CultureInfo.InvariantCulture, out var magnitude)) return null;
        return (sign == '-' ? -magnitude : magnitude, s[i], i - at + 1);
    }

    public static string FormatTextExpanderCode(string code, DateTime date, CultureInfo culture)
    {
        foreach (var (c, pattern) in TextExpanderCodes)
            if (c == code) return date.ToString(DatePattern.ToDotNet(pattern), culture);
        return "%" + code;
    }
}

/// <summary>
/// Unicode(LDML) 날짜 패턴 → .NET 사용자 지정 형식. Mac 에서 쓴 <c>yyyy-MM-dd EEEE a</c> 가
/// Windows 에서도 같은 결과를 내도록 흔히 쓰는 기호를 옮긴다. 옮길 수 없는 글자와 모든
/// 비문자는 그대로 찍히도록 이스케이프한다(.NET 은 'g', 'z', 'K' 등도 형식 기호로 읽는다).
/// </summary>
public static class DatePattern
{
    public static string ToDotNet(string ldml)
    {
        var sb = new StringBuilder();
        var tokens = 0;
        var i = 0;
        while (i < ldml.Length)
        {
            var c = ldml[i];
            if (c == '\'')
            {
                // '' 는 작은따옴표 하나, '…' 는 그대로 찍을 글자.
                if (i + 1 < ldml.Length && ldml[i + 1] == '\'') { Literal(sb, '\''); i += 2; continue; }
                var end = ldml.IndexOf('\'', i + 1);
                var text = end < 0 ? ldml[(i + 1)..] : ldml[(i + 1)..end];
                foreach (var ch in text) Literal(sb, ch);
                i = end < 0 ? ldml.Length : end + 1;
                continue;
            }
            if (!char.IsAsciiLetter(c)) { Literal(sb, c); i++; continue; }

            var run = 1;
            while (i + run < ldml.Length && ldml[i + run] == c) run++;
            var mapped = Map(c, run);
            if (mapped is null) { for (var k = 0; k < run; k++) Literal(sb, c); }
            else { sb.Append(mapped); tokens++; }
            i += run;
        }
        var result = sb.ToString();
        // .NET 은 한 글자짜리 형식을 '표준 형식'으로 읽는다("M" → "March 5"). % 를 붙여 막는다.
        return tokens == 1 && result.Length == 1 ? "%" + result : result;
    }

    private static string? Map(char c, int n) => c switch
    {
        'y' or 'u' => n == 2 ? "yy" : "yyyy",
        'M' or 'L' => n switch { 1 => "M", 2 => "MM", 3 => "MMM", _ => "MMMM" },
        'd' => n == 1 ? "d" : "dd",
        'E' or 'c' or 'e' when n >= 3 => n >= 4 ? "dddd" : "ddd",
        'E' => "ddd",
        'a' => "tt",
        'H' => n == 1 ? "H" : "HH",
        'h' => n == 1 ? "h" : "hh",
        'm' => n == 1 ? "m" : "mm",
        's' => n == 1 ? "s" : "ss",
        'S' => new string('f', Math.Min(n, 7)),
        _ => null,
    };

    private static void Literal(StringBuilder sb, char c) => sb.Append('\\').Append(c);
}
