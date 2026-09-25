using System.Text.Json;
using System.Text.Json.Serialization;

namespace SnipKey.Core;

/// <summary>
/// Windows 기기 전용 설정. 동기화되는 store.json 에 넣지 않는다 — 확장 켜기/끄기와
/// 제외 앱은 기기마다 다르고(macOS 판 B7 참고), 키 코드는 OS 마다 다르다.
/// </summary>
public sealed class LocalSettings
{
    public bool ExpansionEnabled { get; set; } = true;
    public bool PlaySound { get; set; }
    public bool UndoWithBackspace { get; set; } = true;
    /// <summary>확장하지 않을 프로그램의 실행 파일 이름(소문자, 예: "windowsterminal.exe").</summary>
    public List<string> ExcludedApps { get; set; } = new();
    /// <summary>검색 팔레트 단축키. 기본 Ctrl+Shift+Space.</summary>
    public int SearchHotkeyModifiers { get; set; } = 0x0002 | 0x0004; // MOD_CONTROL | MOD_SHIFT
    public int SearchHotkeyKey { get; set; } = 0x20; // VK_SPACE
    public bool SearchEnabled { get; set; } = true;
    /// <summary>동기화 폴더의 라이브러리 경로. null 이면 %APPDATA%\SnipKey\store.json.</summary>
    public string? LibraryPath { get; set; }
    /// <summary>"system", "en", "ko", "ja".</summary>
    public string Language { get; set; } = "system";
    /// <summary>이보다 긴 텍스트(또는 여러 줄)는 타이핑 대신 클립보드로 붙여 넣는다.</summary>
    public int TypeMaxLength { get; set; } = 120;
    public int ClipboardRestoreDelayMs { get; set; } = 350;

    public bool IsExcluded(string? exeName) =>
        exeName is not null && ExcludedApps.Contains(exeName.ToLowerInvariant());

    private static readonly JsonSerializerOptions Json = new()
    {
        WriteIndented = true,
        DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingNull,
    };

    public static LocalSettings Load(string path)
    {
        try
        {
            if (File.Exists(path))
                return JsonSerializer.Deserialize<LocalSettings>(File.ReadAllText(path), Json) ?? new();
        }
        catch (JsonException) { }
        catch (IOException) { }
        return new();
    }

    public void Save(string path)
    {
        Directory.CreateDirectory(Path.GetDirectoryName(path)!);
        File.WriteAllText(path, JsonSerializer.Serialize(this, Json));
    }
}
