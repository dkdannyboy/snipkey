using System.Text;

namespace SnipKey.Core;

/// <summary>macOS 판 Store.Matcher 의 이식. 확정된 매치: 무엇을 몇 글자 지우고 무엇을 다시 찍을지.</summary>
public sealed record Match(Snippet Snippet, int Backspaces, string Terminator, string Typed);

/// <summary>
/// 켜진 그룹의 켜진 스니펫으로 만든 색인. 버퍼 끝에서 발화 조건을 만족하는 가장 긴 약어를 찾는다.
///
/// 약어는 두 부류이고 발화 조건이 다르다.
/// 1) 구두점으로 시작(<c>;sig</c>) — 접두 구두점이 스스로 경계라 즉시 발화한다.
/// 2) 단어 문자로 시작(<c>sig</c>) — 더 긴 단어(<c>signal</c>)의 앞부분일 수 있으므로
///    &lt;경계&gt;&lt;약어&gt;&lt;종결자&gt; 로 끝나야 발화하고, 종결자를 함께 지웠다가 다시 찍는다.
/// </summary>
public sealed class Matcher
{
    public int MaxLength { get; }
    private readonly Dictionary<string, Snippet> _exact;
    private readonly Dictionary<string, Snippet> _insensitive;

    public Matcher(int maxLength, Dictionary<string, Snippet> exact, Dictionary<string, Snippet> insensitive)
    {
        MaxLength = maxLength;
        _exact = exact;
        _insensitive = insensitive;
    }

    public static readonly Matcher Empty = new(0, new(), new());

    public static Matcher Build(IEnumerable<SnippetGroup> groups)
    {
        var exact = new Dictionary<string, Snippet>(StringComparer.Ordinal);
        var insensitive = new Dictionary<string, Snippet>(StringComparer.Ordinal);
        var max = 0;
        foreach (var g in groups.Where(g => g.Enabled))
        foreach (var s in g.Snippets.Where(s => s.Enabled && s.Abbreviation.Length > 0))
        {
            max = Math.Max(max, TextElements.Count(s.Abbreviation));
            if (MatchesCaseInsensitively(s)) insensitive[Lower(s.Abbreviation)] = s;
            else exact[s.Abbreviation] = s;
        }
        return new Matcher(max, exact, insensitive);
    }

    public static bool MatchesCaseInsensitively(Snippet s) => !s.CaseSensitive || s.AdaptCase;

    internal static string Lower(string s) => s.ToLowerInvariant();

    public Snippet? Lookup(string abbreviation) =>
        _exact.TryGetValue(abbreviation, out var s) ? s
        : _insensitive.TryGetValue(Lower(abbreviation), out var t) ? t : null;

    /// <summary>유니코드 기준 단어 문자. ASCII 만 보면 한글·악센트 라틴이 '경계'로 잘못 분류된다.</summary>
    public static bool IsWordCharacter(string element)
    {
        if (element.Length == 0) return false;
        if (element == "_") return true;
        var rune = Rune.GetRuneAt(element, 0);
        return Rune.IsLetter(rune) || Rune.IsNumber(rune);
    }

    public Match? Find(IReadOnlyList<string> chars)
    {
        var n = chars.Count;
        if (MaxLength == 0 || n == 0) return null;
        var upper = Math.Min(MaxLength, n);

        string Join(int from, int to)
        {
            var sb = new StringBuilder();
            for (var k = from; k < to; k++) sb.Append(chars[k]);
            return sb.ToString();
        }

        for (var len = upper; len >= 1; len--)
        {
            // (1) 구두점 시작 약어 — 버퍼가 약어로 끝나면 즉시.
            var start = n - len;
            var whole = Join(start, n);
            if (!IsWordCharacter(chars[start]) && Lookup(whole) is { } punct)
                return new Match(punct, len, "", whole);

            // (2) 맨몸 약어 — <경계><약어><종결자>.
            var abbrevEnd = n - 1;
            var abbrevStart = abbrevEnd - len;
            if (abbrevStart >= 0
                && !IsWordCharacter(chars[abbrevEnd])
                && IsWordCharacter(chars[abbrevStart])
                && (abbrevStart == 0 || !IsWordCharacter(chars[abbrevStart - 1])))
            {
                var typed = Join(abbrevStart, abbrevEnd);
                if (Lookup(typed) is { } bare)
                {
                    var terminator = chars[abbrevEnd];
                    return new Match(bare, len + 1, terminator, typed);
                }
            }
        }
        return null;
    }
}
