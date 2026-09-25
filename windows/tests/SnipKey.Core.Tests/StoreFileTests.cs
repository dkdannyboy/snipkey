using System.Text;
using System.Text.Json.Nodes;
using SnipKey.Core;

namespace SnipKey.Core.Tests;

/// <summary>
/// Mac 과 Windows 가 같은 store.json 을 번갈아 쓸 수 있는가. Fixtures/mac-store.json 은
/// macOS 앱 자신의 코드(headless --import-te)가 실제로 쓴 파일이다.
/// </summary>
public sealed class StoreFileTests : IDisposable
{
    private readonly string _dir = Path.Combine(Path.GetTempPath(), "snipkey-win-" + Guid.NewGuid());
    private static string Fixture => Path.Combine(AppContext.BaseDirectory, "Fixtures", "mac-store.json");

    public StoreFileTests() => Directory.CreateDirectory(_dir);
    public void Dispose() => Directory.Delete(_dir, recursive: true);

    private string Copy(string name = "store.json")
    {
        var path = Path.Combine(_dir, name);
        File.Copy(Fixture, path);
        return path;
    }

    [Fact]
    public void ReadsTheMacFile()
    {
        var file = new StoreFile(Copy());
        var data = file.Load();
        Assert.Equal(LoadStatus.Ok, file.Status);
        var snippets = data.Groups.Single().Snippets;
        Assert.Equal(new[] { "~fx1", "~fx2" }, snippets.Select(s => s.Abbreviation));
        Assert.Equal("한국어 확장 테스트", snippets[1].Content);
        Assert.False(snippets[1].CaseSensitive);
        Assert.Equal(new DateTime(2023, 9, 8, 6, 49, 3, DateTimeKind.Utc), snippets[0].CreatedAt);
    }

    [Fact]
    public void RoundTripPreservesEveryMacKeyAndValue()
    {
        var path = Copy();
        var file = new StoreFile(path);
        var data = file.Load();
        Assert.Equal(SaveOutcome.Saved, file.Save(data));

        var before = JsonNode.Parse(File.ReadAllText(Fixture))!;
        var after = JsonNode.Parse(File.ReadAllText(path))!;
        // Mac 전용 설정(excludedBundleIDs, inlineSearchKeyCode …)과 macros 까지 그대로여야 한다.
        Assert.True(JsonNode.DeepEquals(before, after), $"round trip changed the file:\n{after}");
    }

    [Fact]
    public void WrittenFileUsesMacDateAndIdFormat()
    {
        var path = Path.Combine(_dir, "new.json");
        var file = new StoreFile(path);
        var data = file.Load();
        var snippet = new Snippet { Abbreviation = ";w", Content = "win" };
        data.Groups.Add(new SnippetGroup { Name = "Windows", Snippets = { snippet } });
        Assert.Equal(SaveOutcome.Saved, file.Save(data));

        var text = File.ReadAllText(path);
        Assert.Contains(snippet.Id.ToString().ToUpperInvariant(), text);
        Assert.Matches("\"createdAt\": \"\\d{4}-\\d\\d-\\d\\dT\\d\\d:\\d\\d:\\d\\dZ\"", text);
        Assert.Contains("\"version\": 2", text);
        Assert.Contains("\"expansionCount\"", text);
        Assert.DoesNotContain("adaptCase", text);
    }

    [Fact]
    public void AdaptCaseIsWrittenOnlyWhenOn()
    {
        var path = Path.Combine(_dir, "adapt.json");
        var file = new StoreFile(path);
        var data = file.Load();
        data.Groups.Add(new SnippetGroup { Name = "g", Snippets = { new Snippet { Abbreviation = ";a", AdaptCase = true } } });
        file.Save(data);
        Assert.Contains("\"adaptCase\": true", File.ReadAllText(path));
        Assert.True(new StoreFile(path).Load().Groups[0].Snippets[0].AdaptCase);
    }

    [Fact]
    public void RefusesToOverwriteAChangeFromAnotherDevice()
    {
        var path = Copy();
        var mine = new StoreFile(path);
        var data = mine.Load();

        // 다른 기기(Mac)가 그사이 파일을 바꿨다.
        var other = new StoreFile(path);
        var theirs = other.Load();
        theirs.Groups[0].Snippets[0].Content = "edited on Mac";
        Assert.Equal(SaveOutcome.Saved, other.Save(theirs));

        data.Groups[0].Snippets[0].Content = "edited on Windows";
        Assert.Equal(SaveOutcome.ChangedOnDisk, mine.Save(data));
        Assert.Contains("edited on Mac", File.ReadAllText(path));
    }

    [Fact]
    public void UnreadableFileIsKeptAndSavingIsBlocked()
    {
        var path = Path.Combine(_dir, "store.json");
        File.WriteAllText(path, "{ not json");
        var file = new StoreFile(path);
        var data = file.Load();
        Assert.Equal(LoadStatus.Unreadable, file.Status);
        Assert.NotNull(file.UnreadableBackupPath);
        Assert.True(File.Exists(file.UnreadableBackupPath));
        Assert.Equal(SaveOutcome.Blocked, file.Save(data));
        Assert.Equal("{ not json", File.ReadAllText(path));
    }

    [Fact]
    public void SnippetMissingARequiredKeyIsUnreadableNotSilentlyDefaulted()
    {
        var path = Path.Combine(_dir, "store.json");
        var node = JsonNode.Parse(File.ReadAllText(Fixture))!;
        node["groups"]![0]!["snippets"]![0]!.AsObject().Remove("content");
        File.WriteAllText(path, node.ToJsonString());
        var file = new StoreFile(path);
        file.Load();
        Assert.Equal(LoadStatus.Unreadable, file.Status);
    }

    [Fact]
    public void FutureVersionIsReadOnly()
    {
        var path = Path.Combine(_dir, "store.json");
        var node = JsonNode.Parse(File.ReadAllText(Fixture))!;
        node["version"] = 99;
        File.WriteAllText(path, node.ToJsonString());
        var file = new StoreFile(path);
        var data = file.Load();
        Assert.Equal(LoadStatus.FutureVersion, file.Status);
        Assert.Equal(SaveOutcome.Blocked, file.Save(data));
    }

    [Fact]
    public void OverwriteKeepsABackup()
    {
        var path = Copy();
        var file = new StoreFile(path);
        var data = file.Load();
        data.Groups[0].Name = "Renamed";
        file.Save(data);
        Assert.True(File.Exists(path + ".bak"));
        Assert.Contains("Fixture Group", File.ReadAllText(path + ".bak"));
    }

    // ---- Library: 다시 읽기 vs 충돌 ----

    [Fact]
    public void ExternalChangeWithoutLocalEditsReloadsQuietly()
    {
        var path = Copy();
        var lib = new Library(path);
        var other = new StoreFile(path);
        var theirs = other.Load();
        theirs.Groups[0].Snippets[0].Content = "from Mac";
        other.Save(theirs);

        Assert.Null(lib.ExternalChange());
        Assert.Equal("from Mac", lib.Data.Groups[0].Snippets[0].Content);
    }

    [Fact]
    public void ExternalChangeWithLocalEditsKeepsBothVersions()
    {
        var path = Copy();
        var lib = new Library(path);
        lib.Data.Groups[0].Snippets[0].Content = "unsaved Windows edit";

        var other = new StoreFile(path);
        var theirs = other.Load();
        theirs.Groups[0].Snippets[0].Content = "from Mac";
        other.Save(theirs);

        var conflict = lib.ExternalChange();
        Assert.NotNull(conflict);
        Assert.Contains("unsaved Windows edit", File.ReadAllText(conflict!, Encoding.UTF8));
        Assert.Equal("from Mac", lib.Data.Groups[0].Snippets[0].Content);
    }

    [Fact]
    public void NestedLookupUsesMatcherRules()
    {
        var path = Path.Combine(_dir, "store.json");
        var lib = new Library(path);
        lib.Data.Groups.Add(new SnippetGroup
        {
            Name = "g",
            Snippets =
            {
                new Snippet { Abbreviation = ";x", Content = "disabled", Enabled = false },
                new Snippet { Abbreviation = ";x", Content = "enabled" },
                new Snippet { Abbreviation = ";Addr", Content = "Seoul", CaseSensitive = false },
            },
        });
        lib.Commit();
        Assert.Equal("enabled", lib.SnippetFor(";x")!.Content);
        Assert.Equal("Seoul", lib.SnippetFor(";addr")!.Content);
    }
}
