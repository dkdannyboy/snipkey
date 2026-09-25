using SnipKey.Core;

namespace SnipKey.Core.Tests;

/// <summary>매칭 규칙(macOS MatcherTests)과 엔진 결정: 대소문자 따라가기, 되돌리기.</summary>
public class EngineTests
{
    private static Snippet S(string abbr, string content = "X", bool caseSensitive = true, bool adapt = false, bool enabled = true) =>
        new() { Abbreviation = abbr, Content = content, CaseSensitive = caseSensitive, AdaptCase = adapt, Enabled = enabled };

    private static EngineCore Engine(params Snippet[] snippets) =>
        new() { Matcher = Matcher.Build(new[] { new SnippetGroup { Name = "g", Snippets = snippets.ToList() } }) };

    private static EngineAction Type(EngineCore e, string text)
    {
        EngineAction last = EngineAction.Nothing;
        foreach (var ch in TextElements.Split(text))
        {
            last = e.Handle(new KeyInput.Character(ch));
            if (last is EngineAction.Expand) return last;
        }
        return last;
    }

    [Fact]
    public void PunctuationAbbreviationFiresImmediately()
    {
        var m = Assert.IsType<EngineAction.Expand>(Type(Engine(S(";sig")), "hi ;sig")).Match;
        Assert.Equal(4, m.Backspaces);
        Assert.Equal("", m.Terminator);
    }

    [Fact]
    public void BareWordWaitsForTerminator()
    {
        var e = Engine(S("sig"));
        Assert.IsType<EngineAction.None>(Type(e, "sig"));
        var m = Assert.IsType<EngineAction.Expand>(e.Handle(new KeyInput.Character(" "))).Match;
        Assert.Equal(4, m.Backspaces);
        Assert.Equal(" ", m.Terminator);
        Assert.Equal("sig", m.Typed);
    }

    [Fact]
    public void BareWordInsideLongerWordDoesNotFire()
    {
        Assert.IsType<EngineAction.None>(Type(Engine(S("sig")), "signal "));
        Assert.IsType<EngineAction.None>(Type(Engine(S("sig")), "desig "));
    }

    [Fact]
    public void HangulIsAWordCharacter()
    {
        // 한글 뒤에 붙은 맨몸 약어는 단어 안쪽이다.
        Assert.IsType<EngineAction.None>(Type(Engine(S("sig")), "가sig "));
        Assert.IsType<EngineAction.Expand>(Type(Engine(S("ㄱㅅ", "감사합니다")), "ㄱㅅ "));
    }

    [Fact]
    public void LongestAbbreviationWins()
    {
        var m = Assert.IsType<EngineAction.Expand>(Type(Engine(S(";a", "short"), S(";ab", "long")), ";ab")).Match;
        // ";a" 는 ";ab" 를 치는 도중 먼저 발화한다 — 구두점 약어는 즉시 발화하므로, 이게 Mac 과 같은 동작이다.
        Assert.Equal("short", m.Snippet.Content);
    }

    [Fact]
    public void CaseInsensitiveAndDisabled()
    {
        Assert.IsType<EngineAction.Expand>(Type(Engine(S(";Addr", caseSensitive: false)), ";addr"));
        Assert.IsType<EngineAction.None>(Type(Engine(S(";Addr")), ";addr"));
        Assert.IsType<EngineAction.None>(Type(Engine(S(";x", enabled: false)), ";x"));
    }

    [Fact]
    public void InvalidateAndBackspaceEditTheBuffer()
    {
        var e = Engine(S(";sig"));
        Type(e, ";si");
        e.Handle(new KeyInput.Invalidate());
        Assert.IsType<EngineAction.None>(Type(e, "g"));
        Type(e, ";sx");
        e.Handle(new KeyInput.Backspace());
        Assert.IsType<EngineAction.Expand>(Type(e, "ig"));
    }

    [Fact]
    public void DisabledEngineDoesNothing()
    {
        var e = Engine(S(";sig"));
        e.Enabled = false;
        Assert.IsType<EngineAction.None>(Type(e, ";sig"));
    }

    // ---- 대소문자 따라가기 ----

    [Theory]
    [InlineData(";sig", "best regards")]
    [InlineData(";Sig", "Best regards")]
    [InlineData(";SIG", "BEST REGARDS")]
    public void AdaptCase(string typed, string expected)
    {
        var m = Assert.IsType<EngineAction.Expand>(Type(Engine(S(";sig", adapt: true)), typed)).Match;
        Assert.Equal(expected, CaseAdapter.Adapt("best regards", m.Typed, m.Snippet.Abbreviation));
    }

    [Fact]
    public void AdaptCaseNoOpForUncasedScripts() =>
        Assert.Equal("감사합니다", CaseAdapter.Adapt("감사합니다", ";ㄱㅅ", ";ㄱㅅ"));

    // ---- 되돌리기 ----

    [Fact]
    public void BackspaceRightAfterExpansionUndoes()
    {
        var e = Engine(S("sig"));
        var plan = ExpansionUndo.For("Best regards ", "sig", " ", 0, Array.Empty<string>())!;
        Assert.Equal(12, plan.Backspaces);
        Assert.Equal("sig ", plan.Restore);
        e.ArmUndo(plan);
        Assert.Equal(plan, Assert.IsType<EngineAction.Undo>(e.Handle(new KeyInput.Backspace())).Plan);
    }

    [Fact]
    public void AnyOtherInputDisarmsUndo()
    {
        var e = Engine(S("sig"));
        e.ArmUndo(new ExpansionUndo.Plan(3, ";a"));
        e.Handle(new KeyInput.Character("x"));
        Assert.IsType<EngineAction.None>(e.Handle(new KeyInput.Backspace()));
    }

    [Fact]
    public void UndoCanBeTurnedOff()
    {
        var e = Engine(S("sig"));
        e.UndoWithBackspace = false;
        e.ArmUndo(new ExpansionUndo.Plan(3, ";a"));
        Assert.IsType<EngineAction.None>(e.Handle(new KeyInput.Backspace()));
    }

    [Fact]
    public void IneligibleExpansionsHaveNoUndoPlan()
    {
        Assert.Null(ExpansionUndo.For("x y", ";a", "", 2, Array.Empty<string>()));
        Assert.Null(ExpansionUndo.For("x y", ";a", "", 0, new[] { "enter" }));
        Assert.Null(ExpansionUndo.For("x y", "", "", 0, Array.Empty<string>()));
        Assert.Null(ExpansionUndo.For(new string('a', ExpansionUndo.MaxUndoLength + 1), ";a", "", 0, Array.Empty<string>()));
    }

    // ---- 검색 ----

    [Fact]
    public void SearchRanksAbbreviationBeforeContentAndStripsSigils()
    {
        var groups = new[]
        {
            new SnippetGroup { Name = "g", Snippets = { S("~clear", "x"), S(";zz", "please clear this"), S(";off", "clear", enabled: false) } },
        };
        var hits = SnippetSearch.Run("clear", groups, includeDisabled: false);
        Assert.Equal(new[] { "~clear", ";zz" }, hits.Select(h => h.Snippet.Abbreviation));
    }

    [Fact]
    public void DuplicateAbbreviationNaming()
    {
        Assert.Equal(";sig3", AbbreviationNaming.Duplicate(";sig", new HashSet<string> { ";sig", ";sig2" }));
        Assert.Equal("", AbbreviationNaming.Duplicate("", new HashSet<string> { "" }));
    }
}
