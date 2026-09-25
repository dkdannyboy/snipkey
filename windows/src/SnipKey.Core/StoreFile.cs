using System.Security.Cryptography;
using System.Text.Json;

namespace SnipKey.Core;

public enum LoadStatus
{
    /// <summary>정상적으로 읽었다(파일이 없으면 빈 라이브러리로 시작).</summary>
    Ok,
    /// <summary>파일이 있는데 읽을 수 없다. 사본을 남기고 저장을 막는다.</summary>
    Unreadable,
    /// <summary>이 빌드보다 새 스키마. 더 새로운 앱이 쓴 파일이라 건드리지 않는다.</summary>
    FutureVersion,
}

public enum SaveOutcome
{
    Saved,
    /// <summary>불러오기에 실패했거나 미래 버전이라 저장하지 않았다.</summary>
    Blocked,
    /// <summary>마지막으로 읽은 뒤 다른 기기가 파일을 바꿨다. 덮어쓰지 않았다.</summary>
    ChangedOnDisk,
    Failed,
}

/// <summary>
/// store.json 한 개를 안전하게 읽고 쓴다. macOS 판의 안전장치와 같은 원칙:
/// <list type="bullet">
/// <item>읽지 못한 파일 위에 새로 시작하지 않는다 — 사본을 남기고 저장을 막는다.</item>
/// <item>마지막으로 읽은 뒤 파일이 바뀌었으면(동기화 폴더의 다른 기기) 덮어쓰지 않는다(비교 후 교체).</item>
/// <item>덮어쓸 때는 직전 내용을 .bak 으로 남기고 원자적으로 교체한다.</item>
/// </list>
/// </summary>
public sealed class StoreFile
{
    public string FilePath { get; }
    public LoadStatus Status { get; private set; } = LoadStatus.Ok;
    public string? UnreadableBackupPath { get; private set; }
    public string? LoadError { get; private set; }
    /// <summary>마지막으로 읽거나 쓴 파일 바이트의 SHA-256. 파일이 없으면 null.</summary>
    public string? LastKnownHash { get; private set; }

    public StoreFile(string filePath) => FilePath = filePath;

    public StoreData Load()
    {
        Status = LoadStatus.Ok;
        LoadError = null;
        UnreadableBackupPath = null;
        if (!File.Exists(FilePath))
        {
            LastKnownHash = null;
            return StoreData.NewEmpty();
        }

        byte[] raw;
        try { raw = File.ReadAllBytes(FilePath); }
        catch (IOException e) { return Fail(e.Message, null); }
        catch (UnauthorizedAccessException e) { return Fail(e.Message, null); }

        LastKnownHash = Hash(raw);
        StoreData data;
        try { data = StoreJson.Deserialize(raw); }
        catch (JsonException e) { return Fail(e.Message, raw); }

        if (data.Version > StoreData.CurrentVersion)
        {
            Status = LoadStatus.FutureVersion;
            LoadError = $"store version {data.Version} is newer than this app understands ({StoreData.CurrentVersion})";
        }
        return data;
    }

    private StoreData Fail(string message, byte[]? raw)
    {
        Status = LoadStatus.Unreadable;
        LoadError = message;
        if (raw is not null)
        {
            var dir = Path.GetDirectoryName(FilePath)!;
            var name = $"{Path.GetFileNameWithoutExtension(FilePath)} (unreadable {DateTime.Now:yyyyMMdd-HHmmss}).json";
            UnreadableBackupPath = Path.Combine(dir, name);
            try { File.WriteAllBytes(UnreadableBackupPath, raw); }
            catch (IOException) { UnreadableBackupPath = null; }
        }
        return StoreData.NewEmpty();
    }

    /// <summary>디스크의 파일이 마지막으로 읽거나 쓴 것과 다른가.</summary>
    public bool ChangedOnDisk() => CurrentHash() != LastKnownHash;

    public SaveOutcome Save(StoreData data) => Write(data, force: false);

    /// <summary>충돌을 사용자가 해결한 뒤(내 것 유지)에만 쓴다.</summary>
    public SaveOutcome ForceSave(StoreData data) => Write(data, force: true);

    private SaveOutcome Write(StoreData data, bool force)
    {
        if (Status != LoadStatus.Ok) return SaveOutcome.Blocked;
        if (!force && ChangedOnDisk()) return SaveOutcome.ChangedOnDisk;

        data.Version = StoreData.CurrentVersion;
        var raw = StoreJson.Serialize(data);
        try
        {
            Directory.CreateDirectory(Path.GetDirectoryName(FilePath)!);
            var temp = FilePath + ".tmp";
            File.WriteAllBytes(temp, raw);
            if (File.Exists(FilePath)) File.Replace(temp, FilePath, FilePath + ".bak", ignoreMetadataErrors: true);
            else File.Move(temp, FilePath);
            LastKnownHash = Hash(raw);
            return SaveOutcome.Saved;
        }
        catch (IOException) { return SaveOutcome.Failed; }
        catch (UnauthorizedAccessException) { return SaveOutcome.Failed; }
    }

    /// <summary>충돌 시 내 쪽 내용을 옆 파일로 남긴다. 어느 쪽도 잃지 않는다.</summary>
    public string? WriteConflictCopy(StoreData data)
    {
        var dir = Path.GetDirectoryName(FilePath)!;
        var path = Path.Combine(dir, $"{Path.GetFileNameWithoutExtension(FilePath)} (conflict {DateTime.Now:yyyyMMdd-HHmmss}).json");
        try { File.WriteAllBytes(path, StoreJson.Serialize(data)); return path; }
        catch (IOException) { return null; }
    }

    private string? CurrentHash()
    {
        try { return File.Exists(FilePath) ? Hash(File.ReadAllBytes(FilePath)) : null; }
        catch (IOException) { return LastKnownHash; }
    }

    private static string Hash(byte[] raw) => Convert.ToHexString(SHA256.HashData(raw));
}
