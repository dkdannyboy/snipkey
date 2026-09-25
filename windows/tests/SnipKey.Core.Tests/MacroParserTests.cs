using System.Globalization;
using SnipKey.Core;

namespace SnipKey.Core.Tests;

/// <summary>macOS 판 MacroParserTests / MacroRenderTests / DateMacroTests 와 같은 사례.</summary>
public class MacroParserTests
{
    private static readonly DateTime Now = new(2026, 3, 5, 14, 7, 9); // 목요일
    private static readonly CultureInfo En = CultureInfo.GetCultureInfo("en-US");

    private static string Render(string content, Dictionary<int, string>? values = null) =>
        MacroParser.Render(MacroParser.Parse(content), values, () => "CLIP", Now, En).Text;

    [Fact]
    public void PlainTextAndUrlEncodingPassThrough()
    {
        const string content = "https://x.com/?q=%EB%AF%B8%EA%B5%AD 100%certain";
        Assert.Equal(content, Render(content));
    }

    [Fact]
    public void FillTextWithValueAndDefault()
    {
        Assert.Equal("Download \"http://a.b\" now",
            Render("Download \"%filltext:name=URL%\" now", new() { [0] = "http://a.b" }));
        Assert.Equal("world", Render("%filltext:name=who:default=world%"));
    }

    [Fact]
    public void DefaultValueKeepsColons()
    {
        Assert.Equal("https://example.com:8080/x", Render("%filltext:name=u:default=https://example.com:8080/x%"));
        Assert.Equal("10:30", Render("%fillpopup:name=t:9:00:default=10:30%"));
    }

    [Fact]
    public void PopupFallsBackToFirstOption()
    {
        Assert.Equal("one", Render("%fillpopup:name=x:one:two%"));
    }

    [Fact]
    public void CursorClipboardAndKeys()
    {
        var r = MacroParser.Render(MacroParser.Parse("a%|bc%clipboard%key:Enter%"), null, () => "!", Now, En);
        Assert.Equal("abc!", r.Text);
        Assert.Equal(3, r.CursorOffsetFromEnd);
        Assert.Equal(new[] { "enter" }, r.TrailingKeys);
    }

    [Fact]
    public void NestedSnippetsResolveUpToTenDeep()
    {
        var resolved = MacroParser.ResolveNested("x %snippet:a% y", abbr => abbr == "a" ? "[%snippet:a%]" : null);
        Assert.StartsWith("x [[[", resolved);
        Assert.Contains("%snippet:a%", resolved);
        Assert.Equal("x %snippet:zz% y", MacroParser.ResolveNested("x %snippet:zz% y", _ => null));
    }

    // ---- 중첩 선택 구간 (macOS B1) ----

    [Fact]
    public void NestedPartOuterOffSwallowsInner() =>
        Assert.Equal("XY", Render("X%fillpart:name=o:default=no%a%fillpart:name=i:default=yes%b%fillpartend%c%fillpartend%Y"));

    [Fact]
    public void NestedPartOuterOnInnerOff() =>
        Assert.Equal("XacY", Render("X%fillpart:name=o:default=yes%a%fillpart:name=i:default=no%b%fillpartend%c%fillpartend%Y"));

    [Fact]
    public void OffPartWithoutEndKeepsText() =>
        Assert.Equal("keep and this too", Render("keep%fillpart:name=p:default=no% and this too"));

    [Fact]
    public void UserTogglesOuterOff()
    {
        const string content = "X%fillpart:name=o:default=yes%a%fillpart:name=i:default=yes%b%fillpartend%c%fillpartend%Y";
        var outer = MacroParser.FillFields(MacroParser.Parse(content)).First(f => f.Name == "o").Id;
        Assert.Equal("XY", Render(content, new() { [outer] = "no" }));
    }

    // ---- 같은 이름 필드 공유 (macOS F5) ----

    [Fact]
    public void SameNameFieldsAreAskedOnce()
    {
        const string content = "Dear %filltext:name=client%, thanks %filltext:name=client%.";
        var fields = MacroParser.FillFields(MacroParser.Parse(content));
        Assert.Single(fields);
        Assert.Equal("Dear Kim, thanks Kim.", Render(content, new() { [fields[0].Id] = "Kim" }));
    }

    [Fact]
    public void UnnamedFieldsAreNotShared()
    {
        var fields = MacroParser.FillFields(MacroParser.Parse("%filltext:name=%-%filltext:name=%"));
        Assert.Equal(2, fields.Count);
    }

    // ---- 날짜 (macOS F4) ----

    [Theory]
    [InlineData("%date:yyyy-MM-dd%", "2026-03-05")]
    [InlineData("%date:HH:mm%", "14:07")]
    [InlineData("%date:+1d:yyyy-MM-dd%", "2026-03-06")]
    [InlineData("%date:-5d:yyyy-MM-dd%", "2026-02-28")]
    [InlineData("%date:+2w:yyyy-MM-dd%", "2026-03-19")]
    [InlineData("%date:+1M:yyyy-MM-dd%", "2026-04-05")]
    [InlineData("%date:+30m:HH:mm%", "14:37")]
    [InlineData("%date:EEEE, MMMM d%", "Thursday, March 5")]
    [InlineData("%date:M%", "3")]
    [InlineData("%date:h a%", "2 PM")]
    [InlineData("%date:yyyy'년'%", "2026년")]
    [InlineData("%Y-%m-%d", "2026-03-05")]
    [InlineData("%y/%1m/%e", "26/3/5")]
    [InlineData("%A, %B %e", "Thursday, March 5")]
    [InlineData("%a %b", "Thu Mar")]
    [InlineData("%H:%M:%S", "14:07:09")]
    [InlineData("%I %p", "02 PM")]
    [InlineData("%Y-%m-%d → %@+1D%Y-%m-%d", "2026-03-05 → 2026-03-06")]
    [InlineData("%@-1M%B", "February")]
    [InlineData("https://x.com/?q=%EB%AF%B8%EA%B5%AD%B0", "https://x.com/?q=%EB%AF%B8%EA%B5%AD%B0")]
    [InlineData("50%discount 100%Money", "50%discount 100%Money")]
    [InlineData("100% sure, 5%x", "100% sure, 5%x")]
    public void DateMacros(string content, string expected) => Assert.Equal(expected, Render(content));

    [Fact]
    public void LiteralRoundTripsTextExpanderCodes()
    {
        const string content = "%@+1D%Y %date:+1d:yyyy%";
        Assert.Equal(content, string.Concat(MacroParser.Parse(content).Select(MacroParser.Literal)));
    }
}
