namespace SnipKey.Core;

/// <summary>
/// 메모리 안의 라이브러리와 디스크 파일을 잇는 층. 편집 여부(dirty)를 내용 지문으로
/// 판정해, 다른 기기가 파일을 바꿨을 때 '조용히 다시 읽기'와 '충돌'을 구분한다.
/// UI 스레드에서만 쓴다고 가정한다(Windows 앱은 모든 호출을 UI 스레드로 모은다).
/// </summary>
public sealed class Library
{
    private StoreFile _file;
    private string _savedContent = "";

    public StoreData Data { get; private set; } = StoreData.NewEmpty();
    public Matcher Matcher { get; private set; } = Matcher.Empty;
    public StoreFile File => _file;
    /// <summary>색인이 다시 만들어졌다(편집·다시 읽기 모두).</summary>
    public event Action? Changed;
    /// <summary>디스크에서 새로 읽었다 — 들고 있던 스니펫 객체는 더 이상 유효하지 않다.</summary>
    public event Action? Reloaded;

    public Library(string path)
    {
        _file = new StoreFile(path);
        Reload();
    }

    public bool IsReadOnly => _file.Status != LoadStatus.Ok;
    public bool HasUnsavedChanges => Fingerprint(Data) != _savedContent;

    public void Reload()
    {
        Data = _file.Load();
        _savedContent = Fingerprint(Data);
        Rebuild();
        Reloaded?.Invoke();
    }

    /// <summary>다른 파일로 옮긴다. 새 파일을 제대로 읽지 못하면 옮기지 않는다.</summary>
    public bool SwitchTo(string path, out string? error)
    {
        var candidate = new StoreFile(path);
        var data = candidate.Load();
        if (candidate.Status != LoadStatus.Ok)
        {
            error = candidate.LoadError;
            return false;
        }
        _file = candidate;
        Data = data;
        _savedContent = Fingerprint(Data);
        Rebuild();
        Reloaded?.Invoke();
        error = null;
        return true;
    }

    /// <summary>편집을 알린다. 색인을 다시 만들고 저장을 시도한다.</summary>
    public SaveOutcome Commit()
    {
        Rebuild();
        var outcome = _file.Save(Data);
        if (outcome == SaveOutcome.Saved) _savedContent = Fingerprint(Data);
        return outcome;
    }

    /// <summary>
    /// 파일이 바깥에서 바뀌었다. 미저장 편집이 없으면 조용히 다시 읽는다.
    /// 있으면 내 쪽을 옆 파일로 남기고 디스크를 채택한다 — 어느 쪽도 잃지 않는다.
    /// </summary>
    /// <returns>충돌 사본 경로(충돌이 있었을 때만).</returns>
    public string? ExternalChange()
    {
        if (!_file.ChangedOnDisk()) return null;
        string? conflict = null;
        if (HasUnsavedChanges && !IsReadOnly) conflict = _file.WriteConflictCopy(Data);
        Reload();
        return conflict;
    }

    /// <summary>
    /// <c>%snippet:X%</c> 중첩 조회. 실제 확장과 같은 색인을 먼저 보고, 없으면
    /// 켜진 그룹의 첫 번째 정확 일치로 물러난다(macOS 판 B4 와 같은 규칙).
    /// </summary>
    public Snippet? SnippetFor(string abbreviation) =>
        Matcher.Lookup(abbreviation)
        ?? Data.Groups.Where(g => g.Enabled).SelectMany(g => g.Snippets).FirstOrDefault(s => s.Abbreviation == abbreviation);

    public IEnumerable<Snippet> AllSnippets => Data.Groups.SelectMany(g => g.Snippets);

    /// <summary>같은 약어를 쓰는 켜진 스니펫이 둘 이상이면 하나는 절대 발화하지 않는다.</summary>
    public ISet<string> ConflictingAbbreviations()
    {
        var seen = new Dictionary<string, int>(StringComparer.Ordinal);
        foreach (var g in Data.Groups.Where(g => g.Enabled))
        foreach (var s in g.Snippets.Where(s => s.Enabled && s.Abbreviation.Length > 0))
        {
            var key = Matcher.MatchesCaseInsensitively(s) ? Matcher.Lower(s.Abbreviation) : s.Abbreviation;
            seen[key] = seen.GetValueOrDefault(key) + 1;
        }
        return seen.Where(kv => kv.Value > 1).Select(kv => kv.Key).ToHashSet();
    }

    private void Rebuild()
    {
        Matcher = Matcher.Build(Data.Groups);
        Changed?.Invoke();
    }

    private static string Fingerprint(StoreData data) =>
        Convert.ToHexString(System.Security.Cryptography.SHA256.HashData(StoreJson.Serialize(data)));
}
