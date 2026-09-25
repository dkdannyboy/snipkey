using System.Text.Json;
using System.Text.Json.Serialization;

namespace SnipKey.Core;

// macOS 판 SnipKeyKit/Models.swift 의 이식.
//
// store.json 은 두 OS 가 같은 파일(iCloud Drive 등 동기화 폴더)을 함께 만질 수 있으므로,
// 키 이름·날짜 형식·UUID 표기를 Swift 쪽과 바이트 수준까지 맞춘다. 그리고 이 빌드가
// 모르는 키는 [JsonExtensionData] 로 그대로 들고 있다가 다시 써 넣는다 — 모르는 키를
// 버리면, 더 새로운 Mac 이 쓴 필드를 Windows 가 저장하는 순간 조용히 지워 버린다.

public sealed class Snippet
{
    [JsonPropertyName("id")] public Guid Id { get; set; } = Guid.NewGuid();
    [JsonPropertyName("abbreviation")] public string Abbreviation { get; set; } = "";
    [JsonPropertyName("content")] public string Content { get; set; } = "";
    [JsonPropertyName("label")] public string Label { get; set; } = "";
    /// <summary>false 면 대소문자를 가리지 않고 매칭한다.</summary>
    [JsonPropertyName("caseSensitive")] public bool CaseSensitive { get; set; } = true;
    /// <summary>
    /// 입력한 약어의 대소문자를 결과에 옮긴다(;Sig → 첫 글자 대문자, ;SIG → 전부 대문자).
    /// 옛 파일에는 없는 키라 기본값 false 로 읽는다.
    /// </summary>
    // Mac 과 같이 켜져 있을 때만 쓴다 — 안 쓰는 사용자의 동기화 파일이 바뀌지 않게.
    [JsonPropertyName("adaptCase")]
    [JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingDefault)]
    public bool AdaptCase { get; set; }
    [JsonPropertyName("enabled")] public bool Enabled { get; set; } = true;
    [JsonPropertyName("createdAt")] public DateTime CreatedAt { get; set; } = Iso8601.Now();
    [JsonPropertyName("modifiedAt")] public DateTime ModifiedAt { get; set; } = Iso8601.Now();

    [JsonExtensionData] public Dictionary<string, JsonElement>? Extra { get; set; }

    [JsonIgnore] public string DisplayTitle => string.IsNullOrEmpty(Label) ? Abbreviation : Label;

    public Snippet Clone()
    {
        var c = (Snippet)MemberwiseClone();
        c.Extra = Extra is null ? null : new Dictionary<string, JsonElement>(Extra);
        return c;
    }
}

public sealed class SnippetGroup
{
    [JsonPropertyName("id")] public Guid Id { get; set; } = Guid.NewGuid();
    [JsonPropertyName("name")] public string Name { get; set; } = "";
    [JsonPropertyName("enabled")] public bool Enabled { get; set; } = true;
    [JsonPropertyName("snippets")] public List<Snippet> Snippets { get; set; } = new();

    [JsonExtensionData] public Dictionary<string, JsonElement>? Extra { get; set; }
}

/// <summary>
/// 공유 파일의 settings 객체. Mac 전용 값(Carbon 키 코드 등)이 대부분이라 Windows 는
/// expansionEnabled 만 해석하고 나머지는 전부 그대로 보존한다. Windows 전용 설정은
/// 기기-로컬 파일(<see cref="LocalSettings"/>)에 둔다.
/// </summary>
public sealed class SharedSettings
{
    [JsonPropertyName("expansionEnabled")] public bool ExpansionEnabled { get; set; } = true;
    [JsonExtensionData] public Dictionary<string, JsonElement>? Extra { get; set; }
}

public sealed class StoreData
{
    /// <summary>이 빌드가 이해하는 최상위 스키마 버전. 더 높은 파일은 건드리지 않는다.</summary>
    public const int CurrentVersion = 2;

    // 버전 키가 없는 파일은 버전 필드가 생기기 전의 것이다 → 1.
    [JsonPropertyName("version")] public int Version { get; set; } = 1;
    [JsonPropertyName("groups")] public List<SnippetGroup> Groups { get; set; } = new();
    [JsonPropertyName("settings")] public SharedSettings Settings { get; set; } = new();
    // Mac 의 pre-2.0 빌드가 비옵셔널로 요구하는 키. 값은 무의미하지만 빠지면 구버전이
    // 라이브러리 전체를 못 읽으므로 계속 써 넣는다(Models.swift 주석 참고).
    [JsonPropertyName("expansionCount")] public int ExpansionCount { get; set; }

    // macros(핫키 매크로)는 Mac 전용 기능이라 해석하지 않고 Extra 로 보존한다.
    [JsonExtensionData] public Dictionary<string, JsonElement>? Extra { get; set; }

    public static StoreData NewEmpty() => new() { Version = CurrentVersion };
}

/// <summary>Swift JSONEncoder(.iso8601)와 같은 형식: 초 단위, UTC, 'Z'.</summary>
public static class Iso8601
{
    public const string Format = "yyyy-MM-dd'T'HH:mm:ss'Z'";

    public static DateTime Now()
    {
        var n = DateTime.UtcNow;
        return new DateTime(n.Year, n.Month, n.Day, n.Hour, n.Minute, n.Second, DateTimeKind.Utc);
    }
}
