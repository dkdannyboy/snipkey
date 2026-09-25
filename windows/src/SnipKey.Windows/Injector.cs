using System.Collections.Concurrent;
using System.Media;
using System.Runtime.InteropServices;
using SnipKey.Core;

namespace SnipKey.Windows;

/// <summary>
/// 진짜 사용자 입력(키·클릭)의 순번. 확장이 매치된 뒤(무장) 사용자가 무엇이든 입력했다면
/// 확장을 버린다 — 백스페이스가 우리가 계산한 자리가 아닌 곳을 지우게 되기 때문이다.
///
/// 시각이 아니라 **순번**을 쓴다. 시계는 약 15ms 단위라, 같은 틱 안에 들어온 다음 키를
/// 놓친다. 순번은 훅 스레드에서 입력마다 1씩 올라가고, 매치를 일으킨 키의 순번으로
/// 무장하므로 그 뒤의 입력은 하나도 빠지지 않는다.
/// </summary>
internal sealed class InputClock
{
    private long _sequence;

    /// <summary>입력 하나를 기록하고 그 순번을 돌려준다(훅 스레드).</summary>
    public long Mark() => Interlocked.Increment(ref _sequence);

    /// <summary>지금까지의 마지막 순번. 이 뒤로 들어오는 입력은 <see cref="InputSince"/>에 걸린다.</summary>
    public long Current => Interlocked.Read(ref _sequence);

    public bool InputSince(long armedAt) => Current > armedAt;
}

internal sealed record InjectionJob(
    int Backspaces,
    string Text,
    int CursorOffsetFromEnd,
    IReadOnlyList<string> TrailingKeys,
    IntPtr TargetWindow,
    Func<bool>? Cancelled,
    bool PlaySound,
    Action<bool>? Completed);

/// <summary>
/// 백스페이스와 텍스트를 대상 창에 보낸다. 전용 STA 스레드 하나에서 순서대로 처리한다 —
/// 클립보드(OLE)는 STA 가 필요하고, 저장→붙여넣기→복원이 한 작업 안에서 끝나야 두 확장이
/// 겹쳐도 사용자의 클립보드가 우리 텍스트로 바뀌어 남지 않는다.
/// </summary>
internal sealed class Injector : IDisposable
{
    private readonly BlockingCollection<InjectionJob> _jobs = new();
    private readonly Thread _thread;
    private readonly Func<LocalSettings> _settings;

    public Injector(Func<LocalSettings> settings)
    {
        _settings = settings;
        _thread = new Thread(Run) { IsBackground = true, Name = "SnipKey injector" };
        _thread.SetApartmentState(ApartmentState.STA);
        _thread.Start();
    }

    public void Enqueue(InjectionJob job) => _jobs.Add(job);

    public void Dispose() => _jobs.CompleteAdding();

    private void Run()
    {
        foreach (var job in _jobs.GetConsumingEnumerable())
        {
            bool done;
            try { done = Execute(job); }
            catch (Exception e) when (e is not OutOfMemoryException)
            {
                Log.Write("inject error: " + e.Message);
                done = false;
            }
            job.Completed?.Invoke(done);
        }
    }

    private bool Execute(InjectionJob job)
    {
        // 대상 앱이 트리거 키를 다 처리할 시간을 준다.
        Thread.Sleep(40);
        // 사용자가 아직 수정자 키(Shift·AltGr·Ctrl·Win)를 누르고 있으면 우리가 보낼 키가
        // Shift+← (선택), Ctrl+Alt+V 처럼 다른 뜻이 된다. 손을 뗄 때까지 잠깐 기다린다.
        if (!WaitForModifiersReleased(500))
        {
            Log.Write("expansion cancelled — modifier keys still held");
            return false;
        }
        if (job.Backspaces > 0 && job.Cancelled is not null)
        {
            Thread.Sleep(120);
            if (job.Cancelled())
            {
                Log.Write("expansion cancelled — user input after the match");
                return false;
            }
        }
        // 되돌릴 수 없는 키가 나가기 직전의 마지막 확인: 포커스가 그대로인가.
        if (job.TargetWindow != IntPtr.Zero && Native.GetForegroundWindow() != job.TargetWindow)
        {
            Log.Write("expansion cancelled — focus left the original window");
            return false;
        }

        var settings = _settings();
        // 짧은 한 줄은 유니코드 타이핑이 가장 호환성이 좋다(클립보드를 건드리지 않는다).
        // 여러 줄은 붙여 넣어야 한다 — 줄바꿈을 Enter 로 치면 채팅 앱에서 메시지가 보내진다.
        var paste = job.Text.Length > 0
                    && (job.Text.IndexOfAny(new[] { '\n', '\r', '\t' }) >= 0 || job.Text.Length > settings.TypeMaxLength);
        // 클립보드 백업은 백스페이스 '전에' 한다. 백업이 실패해도 아직 아무것도 지우지 않았다.
        var saved = paste ? SnapshotClipboard() : null;

        for (var i = 0; i < job.Backspaces; i++)
        {
            SendKey(Native.VK_BACK);
            Thread.Sleep(3);
        }
        if (job.Backspaces > 0) Thread.Sleep(20);

        if (job.Text.Length == 0) SendAfterText(job);
        else if (!paste) { TypeUnicode(job.Text); SendAfterText(job); }
        else Paste(job.Text, saved, settings.ClipboardRestoreDelayMs, () => SendAfterText(job));

        if (job.PlaySound) SystemSounds.Asterisk.Play();
        return true;
    }

    private static bool WaitForModifiersReleased(int timeoutMs)
    {
        var deadline = Environment.TickCount64 + timeoutMs;
        while (Native.IsKeyDown(Native.VK_SHIFT) || Native.IsKeyDown(Native.VK_CONTROL)
               || Native.IsKeyDown(Native.VK_MENU) || Native.IsKeyDown(Native.VK_LWIN) || Native.IsKeyDown(Native.VK_RWIN))
        {
            if (Environment.TickCount64 > deadline) return false;
            Thread.Sleep(10);
        }
        return true;
    }

    private static void SendAfterText(InjectionJob job)
    {
        if (job.CursorOffsetFromEnd > 0)
        {
            Thread.Sleep(60);
            for (var i = 0; i < job.CursorOffsetFromEnd; i++) { SendKey(Native.VK_LEFT); Thread.Sleep(2); }
        }
        foreach (var name in job.TrailingKeys)
        {
            ushort? vk = name switch
            {
                "enter" or "return" => Native.VK_RETURN,
                "tab" => Native.VK_TAB,
                "esc" or "escape" => Native.VK_ESCAPE,
                "space" => Native.VK_SPACE,
                _ => null,
            };
            if (vk is null) { Log.Write($"unknown %key: '{name}' — skipped"); continue; }
            Thread.Sleep(100);
            SendKey(vk.Value);
        }
    }

    // ---- 입력 ----

    // 원격 데스크톱·가상 머신 클라이언트는 스캔 코드를 전달하므로 채워 둔다. 화살표·Home·End·
    // Delete 는 확장 키 표시가 없으면 숫자 키패드 키로 읽힌다.
    private static bool IsExtended(ushort vk) => vk is Native.VK_LEFT or Native.VK_RIGHT or Native.VK_UP or Native.VK_DOWN
        or Native.VK_HOME or Native.VK_END or Native.VK_PRIOR or Native.VK_NEXT or Native.VK_DELETE or Native.VK_INSERT
        or Native.VK_RCONTROL or Native.VK_RMENU;

    private static Native.INPUT VirtualKey(ushort vk, bool up) => Key(
        vk,
        (ushort)Native.MapVirtualKey(vk, Native.MAPVK_VK_TO_VSC),
        (up ? Native.KEYEVENTF_KEYUP : 0) | (IsExtended(vk) ? Native.KEYEVENTF_EXTENDEDKEY : 0));

    private static Native.INPUT Key(ushort vk, ushort scan, uint flags) => new()
    {
        type = Native.INPUT_KEYBOARD,
        u = new Native.InputUnion
        {
            ki = new Native.KEYBDINPUT { wVk = vk, wScan = scan, dwFlags = flags, dwExtraInfo = KeyboardHook.Marker },
        },
    };

    private static void Send(params Native.INPUT[] inputs) =>
        Native.SendInput((uint)inputs.Length, inputs, Marshal.SizeOf<Native.INPUT>());

    private static void SendKey(ushort vk) => Send(VirtualKey(vk, false), VirtualKey(vk, true));

    private static void TypeUnicode(string text)
    {
        // UTF-16 코드 단위마다 down/up. 서로게이트 쌍(이모지)도 두 단위를 차례로 보내면 된다.
        var inputs = new List<Native.INPUT>(text.Length * 2);
        foreach (var unit in text)
        {
            inputs.Add(Key(0, unit, Native.KEYEVENTF_UNICODE));
            inputs.Add(Key(0, unit, Native.KEYEVENTF_UNICODE | Native.KEYEVENTF_KEYUP));
        }
        Send(inputs.ToArray());
    }

    private static void Paste(string text, DataObject? saved, int restoreDelayMs, Action afterPaste)
    {
        if (!TrySetClipboard(text)) { TypeUnicodeFallback(text); afterPaste(); return; }
        Thread.Sleep(60);
        Send(VirtualKey(Native.VK_CONTROL, false), VirtualKey(Native.VK_V, false),
             VirtualKey(Native.VK_V, true), VirtualKey(Native.VK_CONTROL, true));
        afterPaste();
        Thread.Sleep(Math.Max(200, restoreDelayMs));
        // 그사이 사용자가 새로 복사했다면 그대로 둔다.
        try
        {
            if (Clipboard.ContainsText() && Clipboard.GetText() == text && saved is not null)
                Clipboard.SetDataObject(saved, copy: true, retryTimes: 10, retryDelay: 50);
        }
        catch (Exception e) when (e is not OutOfMemoryException) { Log.Write("clipboard restore failed: " + e.Message); }
    }

    // 클립보드를 못 열면(다른 앱이 붙잡고 있으면) 줄 단위로라도 친다. 줄바꿈은 Shift+Enter —
    // 대부분의 채팅 앱에서 '보내기'가 아니라 '줄바꿈'이다.
    private static void TypeUnicodeFallback(string text)
    {
        var lines = text.Replace("\r\n", "\n").Split('\n');
        for (var i = 0; i < lines.Length; i++)
        {
            if (i > 0)
            {
                Send(VirtualKey(Native.VK_SHIFT, false), VirtualKey(Native.VK_RETURN, false),
                     VirtualKey(Native.VK_RETURN, true), VirtualKey(Native.VK_SHIFT, true));
            }
            if (lines[i].Length > 0) TypeUnicode(lines[i]);
        }
    }

    /// <summary>
    /// 되돌려 놓을 클립보드 백업. 알려진 표준 형식만 복사한다 — 앱 고유 형식은 .NET 이
    /// BinaryFormatter 로 역직렬화하려 들어 예외가 나거나(보안상으로도 원치 않는다) 수 MB 를
    /// 복사하게 된다. 흔한 경우(텍스트·서식·이미지·파일)는 이것으로 충분하다.
    /// </summary>
    private static readonly string[] SafeFormats =
    {
        DataFormats.UnicodeText, DataFormats.Text, DataFormats.Rtf, DataFormats.Html,
        DataFormats.CommaSeparatedValue, DataFormats.Bitmap, DataFormats.FileDrop,
    };

    private static DataObject? SnapshotClipboard()
    {
        try
        {
            var current = Clipboard.GetDataObject();
            if (current is null) return null;
            var copy = new DataObject();
            var any = false;
            foreach (var format in SafeFormats)
            {
                try
                {
                    if (!current.GetDataPresent(format, autoConvert: false)) continue;
                    var data = current.GetData(format, autoConvert: false);
                    if (data is null) continue;
                    copy.SetData(format, data);
                    any = true;
                }
                catch (Exception e) when (e is not OutOfMemoryException) { }
            }
            return any ? copy : null;
        }
        catch (Exception e) when (e is not OutOfMemoryException) { return null; }
    }

    private static bool TrySetClipboard(string text)
    {
        try
        {
            var data = new DataObject(DataFormats.UnicodeText, text);
            // 잠깐 빌려 쓰는 클립보드다 — Win+V 기록과 클라우드 클립보드에 남기지 않는다.
            data.SetData("ExcludeClipboardContentFromMonitorProcessing", new MemoryStream(new byte[] { 0 }));
            data.SetData("CanIncludeInClipboardHistory", new MemoryStream(BitConverter.GetBytes(0)));
            data.SetData("CanUploadToCloudClipboard", new MemoryStream(BitConverter.GetBytes(0)));
            Clipboard.SetDataObject(data, copy: true, retryTimes: 10, retryDelay: 30);
            return true;
        }
        catch (Exception e) when (e is not OutOfMemoryException)
        {
            Log.Write("clipboard busy: " + e.Message);
            return false;
        }
    }
}

internal static class Log
{
    private static readonly object Gate = new();
    public static string DataDirectory { get; } =
        Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "SnipKey");
    private static string LogPath => Path.Combine(DataDirectory, "SnipKey.log");

    /// <summary>문제 해결용 로그. 1MB 를 넘으면 한 번 회전한다. 스니펫 내용은 쓰지 않는다.</summary>
    public static void Write(string message)
    {
        lock (Gate)
        {
            try
            {
                Directory.CreateDirectory(DataDirectory);
                var info = new FileInfo(LogPath);
                if (info.Exists && info.Length > 1_000_000) File.Move(LogPath, LogPath + ".1", overwrite: true);
                File.AppendAllText(LogPath, $"{DateTime.Now:yyyy-MM-dd HH:mm:ss.fff} {message}{Environment.NewLine}");
            }
            catch (IOException) { }
            catch (UnauthorizedAccessException) { }
        }
    }
}
