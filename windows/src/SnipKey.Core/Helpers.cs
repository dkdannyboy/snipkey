using System.Globalization;

namespace SnipKey.Core;

/// <summary>대소문자 따라가기. macOS 판 CaseAdapter.swift 의 이식.</summary>
public static class CaseAdapter
{
    public static string Adapt(string text, string typed, string abbreviation)
    {
        if (typed == abbreviation) return text;
        var cased = typed.Where(c => char.IsUpper(c) || char.IsLower(c)).ToList();
        if (cased.Count == 0) return text;
        if (cased.Count >= 2 && cased.All(char.IsUpper)) return text.ToUpperInvariant();
        if (char.IsUpper(cased[0])) return CapitalizeFirstLetter(text);
        return text;
    }

    private static string CapitalizeFirstLetter(string text)
    {
        var e = StringInfo.GetTextElementEnumerator(text);
        while (e.MoveNext())
        {
            var element = (string)e.Current;
            if (!char.IsLetter(element, 0)) continue;
            var index = e.ElementIndex;
            return text[..index] + element.ToUpperInvariant() + text[(index + element.Length)..];
        }
        return text;
    }
}

/// <summary>확장 직후 백스페이스로 되돌리기. macOS 판 ExpansionUndo.swift 의 이식.</summary>
public static class ExpansionUndo
{
    public const int MaxUndoLength = 400;

    public sealed record Plan(int Backspaces, string Restore);

    public static Plan? For(string inserted, string typed, string terminator, int cursorOffsetFromEnd,
        IReadOnlyCollection<string> trailingKeys)
    {
        var length = TextElements.Count(inserted);
        if (typed.Length == 0 || length == 0 || cursorOffsetFromEnd != 0 || trailingKeys.Count > 0 || length > MaxUndoLength)
            return null;
        return new Plan(length - 1, typed + terminator);
    }
}

/// <summary>검색 결과 한 줄.</summary>
public sealed record SearchHit(Snippet Snippet, Guid GroupId, string GroupName, int Score);

/// <summary>macOS 판 SnippetSearch.swift 의 이식. 약어 → 레이블 → 내용 순으로 순위를 매긴다.</summary>
public static class SnippetSearch
{
    public static List<SearchHit> Run(string query, IEnumerable<SnippetGroup> groups, bool includeDisabled = true, int? limit = null)
    {
        var needle = query.Trim().ToLowerInvariant();
        if (needle.Length == 0) return new();
        var hits = new List<SearchHit>();
        foreach (var g in groups)
        foreach (var s in g.Snippets)
        {
            if (!includeDisabled && !(s.Enabled && g.Enabled)) continue;
            if (Score(s, needle) is { } score) hits.Add(new SearchHit(s, g.Id, g.Name, score));
        }
        hits.Sort((a, b) =>
        {
            if (a.Score != b.Score) return b.Score.CompareTo(a.Score);
            var la = TextElements.Count(a.Snippet.Abbreviation);
            var lb = TextElements.Count(b.Snippet.Abbreviation);
            if (la != lb) return la.CompareTo(lb);
            return string.Compare(a.Snippet.Abbreviation, b.Snippet.Abbreviation, StringComparison.CurrentCultureIgnoreCase);
        });
        return limit is { } l && hits.Count > l ? hits.GetRange(0, l) : hits;
    }

    private static int? Score(Snippet s, string needle)
    {
        var abbreviation = s.Abbreviation.ToLowerInvariant();
        var label = s.Label.ToLowerInvariant();
        var content = s.Content.ToLowerInvariant();
        var bare = abbreviation.TrimStart(c => !char.IsLetterOrDigit(c));
        if (abbreviation == needle || bare == needle) return 100;
        if (abbreviation.StartsWith(needle, StringComparison.Ordinal) || bare.StartsWith(needle, StringComparison.Ordinal)) return 90;
        if (abbreviation.Contains(needle, StringComparison.Ordinal)) return 70;
        if (label.StartsWith(needle, StringComparison.Ordinal)) return 60;
        if (label.Contains(needle, StringComparison.Ordinal)) return 50;
        if (content.Contains(needle, StringComparison.Ordinal)) return 30;
        return null;
    }

    private static string TrimStart(this string s, Func<char, bool> predicate)
    {
        var i = 0;
        while (i < s.Length && predicate(s[i])) i++;
        return s[i..];
    }
}

/// <summary>복제본 약어. 빈 약어는 비운 채로(예전 Mac 버그: "" → "2").</summary>
public static class AbbreviationNaming
{
    public static string Duplicate(string abbreviation, ISet<string> taken)
    {
        if (abbreviation.Length == 0) return "";
        var n = 2;
        while (taken.Contains(abbreviation + n)) n++;
        return abbreviation + n;
    }
}
