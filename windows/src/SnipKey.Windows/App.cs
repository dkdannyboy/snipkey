using Microsoft.Win32;
using SnipKey.Core;

namespace SnipKey.Windows;

/// <summary>
/// 알림 영역(트레이)에 사는 앱 본체. 라이브러리·설정·확장 서비스·창들을 소유하고,
/// 모든 작업을 UI 스레드 하나에서 처리한다.
/// </summary>
internal sealed class App : ApplicationContext
{
    public static string DataDirectory => Log.DataDirectory;
    private static string SettingsPath => Path.Combine(DataDirectory, "windows-settings.json");
    public static string DefaultLibraryPath => Path.Combine(DataDirectory, "store.json");
    /// <summary>Mac 판 "Save Snippets As…"가 동기화 폴더에 만드는 파일 이름과 같다.</summary>
    public const string SyncedFileName = "SnipKey-snippets.json";

    private readonly Control _ui = new();
    private readonly NotifyIcon _tray = new();
    private readonly HotkeyWindow _hotkey = new();
    private readonly ExpansionService _service;
    private readonly SearchPalette _palette;
    private FileSystemWatcher? _watcher;
    private readonly System.Windows.Forms.Timer _watchDebounce = new() { Interval = 500 };
    private ManagerForm? _manager;

    public LocalSettings Settings { get; }
    public Library Library { get; }
    /// <summary>창 위쪽 띠에 보여 줄 상태(읽기 전용, 충돌 등). 없으면 null.</summary>
    public string? StatusMessage { get; private set; }
    public event Action? StatusChanged;

    public App()
    {
        // BeginInvoke 가 UI 스레드로 가려면 창 핸들이 있어야 한다. CreateControl()은 보이지 않는
        // 컨트롤에는 핸들을 만들지 않을 수 있으므로, Handle 을 읽어 확실히 만든다.
        _ = _ui.Handle;
        Settings = LocalSettings.Load(SettingsPath);
        Strings.Language = Settings.Language;

        var path = Settings.LibraryPath ?? DefaultLibraryPath;
        var firstRun = !File.Exists(path);
        Library = new Library(path);
        if (firstRun && Library.File.Status == LoadStatus.Ok) SeedStarterLibrary();
        UpdateStatusFromLoad();

        _service = new ExpansionService(_ui, Library, () => Settings);
        _service.Notify += Balloon;
        _palette = new SearchPalette(Library, _service.ExpandFromSearch);

        _tray.Icon = IconFactory.AppIcon(Settings.ExpansionEnabled);
        _tray.Text = "SnipKey";
        _tray.Visible = true;
        _tray.ContextMenuStrip = new ContextMenuStrip();
        _tray.ContextMenuStrip.Opening += (_, _) => BuildMenu(_tray.ContextMenuStrip);
        _tray.MouseClick += (_, e) => { if (e.Button == MouseButtons.Left) OpenManager(); };

        _hotkey.Pressed += () => _palette.ShowFor(Native.GetForegroundWindow());
        RegisterHotkey();

        _watchDebounce.Tick += (_, _) => { _watchDebounce.Stop(); OnExternalChange(); };
        Watch();

        _service.Start();
        Log.Write($"started — library {Library.File.FilePath}");
        if (firstRun) Balloon(Strings.S("notify.firstRun"));
    }

    // ---- 트레이 메뉴 ----

    private void BuildMenu(ContextMenuStrip menu)
    {
        menu.Items.Clear();
        var toggle = new ToolStripMenuItem(Settings.ExpansionEnabled ? Strings.S("tray.on") : Strings.S("tray.off"))
        {
            Checked = Settings.ExpansionEnabled,
        };
        toggle.Click += (_, _) => { Settings.ExpansionEnabled = !Settings.ExpansionEnabled; SettingsChanged(); };
        menu.Items.Add(toggle);

        // 트레이를 누르는 순간 앞에 있던 프로그램이 곧 사용자가 쓰던 프로그램이다.
        if (_service.LastExternalApp is { } app)
        {
            var exclude = new ToolStripMenuItem(Strings.S("tray.exclude", app.Name)) { Checked = Settings.IsExcluded(app.Exe) };
            exclude.Click += (_, _) =>
            {
                if (!Settings.ExcludedApps.Remove(app.Exe)) Settings.ExcludedApps.Add(app.Exe);
                SettingsChanged();
            };
            menu.Items.Add(exclude);
        }

        menu.Items.Add(new ToolStripSeparator());
        var search = new ToolStripMenuItem(Strings.S("tray.search", HotkeyLabel())) { Enabled = Settings.SearchEnabled };
        search.Click += (_, _) => _palette.ShowFor(IntPtr.Zero);
        menu.Items.Add(search);
        menu.Items.Add(Strings.S("tray.open"), null, (_, _) => OpenManager());
        menu.Items.Add(Strings.S("tray.settings"), null, (_, _) => OpenManager(settings: true));
        menu.Items.Add(new ToolStripMenuItem(Strings.S("tray.stats", Library.AllSnippets.Count(), _service.ExpansionCount)) { Enabled = false });
        menu.Items.Add(new ToolStripSeparator());
        menu.Items.Add(Strings.S("tray.quit"), null, (_, _) => Quit());
    }

    private string HotkeyLabel()
    {
        var parts = new List<string>();
        if ((Settings.SearchHotkeyModifiers & 0x0002) != 0) parts.Add("Ctrl");
        if ((Settings.SearchHotkeyModifiers & 0x0001) != 0) parts.Add("Alt");
        if ((Settings.SearchHotkeyModifiers & 0x0004) != 0) parts.Add("Shift");
        if ((Settings.SearchHotkeyModifiers & 0x0008) != 0) parts.Add("Win");
        parts.Add(Settings.SearchHotkeyKey == 0x20 ? "Space" : ((Keys)Settings.SearchHotkeyKey).ToString());
        return string.Join("+", parts);
    }

    public void OpenManager(bool settings = false)
    {
        if (_manager is null || _manager.IsDisposed)
        {
            _manager = new ManagerForm(this);
            _manager.FormClosed += (_, _) => _manager = null;
        }
        if (settings) _manager.ShowSettings();
        _manager.Show();
        if (_manager.WindowState == FormWindowState.Minimized) _manager.WindowState = FormWindowState.Normal;
        _manager.Activate();
    }

    private void Balloon(string text) => _tray.ShowBalloonTip(5000, "SnipKey", text, ToolTipIcon.Info);

    // ---- 설정 ----

    public void SettingsChanged()
    {
        try { Settings.Save(SettingsPath); }
        catch (IOException e) { Log.Write("settings save failed: " + e.Message); }
        _tray.Icon = IconFactory.AppIcon(Settings.ExpansionEnabled);
        if (Strings.Language != Settings.Language)
        {
            Strings.Language = Settings.Language;
            // 열린 창은 다시 만들어야 새 언어로 그려진다. 이 호출은 그 창의 콤보 상자 이벤트
            // 안에서 오므로, 이벤트가 끝난 뒤에 닫고 다시 연다(해제된 컨트롤을 건드리지 않게).
            if (_manager is { IsDisposed: false } m)
                _ui.BeginInvoke(() => { m.Close(); OpenManager(settings: true); });
        }
        RegisterHotkey();
    }

    private void RegisterHotkey()
    {
        _hotkey.Unregister();
        if (!Settings.SearchEnabled) return;
        if (!_hotkey.Register((uint)Settings.SearchHotkeyModifiers, (uint)Settings.SearchHotkeyKey))
            Balloon(Strings.S("notify.hotkeyFailed", HotkeyLabel()));
    }

    // ---- 라이브러리 ----

    /// <summary>편집을 저장한다. 다른 기기가 먼저 바꿨으면 양쪽을 모두 보존한다.</summary>
    public void Save()
    {
        var outcome = Library.Commit();
        switch (outcome)
        {
            case SaveOutcome.Saved:
                if (StatusMessage == Strings.S("banner.saveFailed")) SetStatus(null);
                break;
            case SaveOutcome.ChangedOnDisk:
                var conflict = Library.ExternalChange();
                if (conflict is not null) SetStatus(Strings.S("banner.conflict", conflict));
                break;
            case SaveOutcome.Failed:
                SetStatus(Strings.S("banner.saveFailed"));
                break;
            case SaveOutcome.Blocked:
                UpdateStatusFromLoad();
                break;
        }
    }

    private void OnExternalChange()
    {
        var conflict = Library.ExternalChange();
        if (conflict is not null) SetStatus(Strings.S("banner.conflict", conflict));
        else UpdateStatusFromLoad();
    }

    private void UpdateStatusFromLoad() => SetStatus(Library.File.Status switch
    {
        LoadStatus.Unreadable => Strings.S("banner.readOnly", Library.File.UnreadableBackupPath ?? Library.File.LoadError ?? "?"),
        LoadStatus.FutureVersion => Strings.S("banner.future"),
        _ => null,
    });

    private void SetStatus(string? message)
    {
        StatusMessage = message;
        StatusChanged?.Invoke();
    }

    private void Watch()
    {
        _watcher?.Dispose();
        var path = Library.File.FilePath;
        var dir = Path.GetDirectoryName(path)!;
        Directory.CreateDirectory(dir);
        _watcher = new FileSystemWatcher(dir, Path.GetFileName(path))
        {
            NotifyFilter = NotifyFilters.LastWrite | NotifyFilters.FileName | NotifyFilters.Size,
            SynchronizingObject = _ui,
            EnableRaisingEvents = true,
        };
        // 동기화 클라이언트는 파일을 여러 번에 나눠 쓴다 — 조용해질 때까지 기다렸다 읽는다.
        void Bump(object? s, EventArgs e) { _watchDebounce.Stop(); _watchDebounce.Start(); }
        _watcher.Changed += Bump;
        _watcher.Created += Bump;
        _watcher.Renamed += Bump;
        // 버퍼 넘침이나 클라우드 폴더가 잠시 사라지면 감시가 조용히 멈춘다 — 다시 건다.
        _watcher.Error += (_, e) =>
        {
            Log.Write("file watcher error: " + e.GetException().Message);
            _ui.BeginInvoke(() => { Watch(); Bump(null, EventArgs.Empty); });
        };
    }

    public bool SaveLibraryAs(string folder, out string? error)
    {
        var target = Path.Combine(folder, SyncedFileName);
        if (File.Exists(target))
        {
            // 이미 있는 라이브러리를 덮어쓰지 않는다 — 그건 '연결'이다.
            error = $"{target} already exists — use \"{Strings.S("settings.library.link")}\"";
            return false;
        }
        var file = new StoreFile(target);
        file.Load();
        if (file.Save(Library.Data) != SaveOutcome.Saved) { error = "write failed"; return false; }
        return LinkLibrary(target, out error);
    }

    public bool LinkLibrary(string path, out string? error)
    {
        if (!Library.SwitchTo(path, out error)) return false;
        Settings.LibraryPath = path;
        SettingsChanged();
        SetStatus(null);
        Watch();
        return true;
    }

    /// <summary>동기화를 그만두고 지금 라이브러리를 로컬 파일로 가져온다(기존 로컬 파일은 .bak).</summary>
    public void UseLocalLibrary()
    {
        if (Settings.LibraryPath is null) return;
        var local = new StoreFile(DefaultLibraryPath);
        local.Load();
        if (local.Status == LoadStatus.Ok) local.ForceSave(Library.Data);
        Library.SwitchTo(DefaultLibraryPath, out _);
        Settings.LibraryPath = null;
        SettingsChanged();
        Watch();
    }

    /// <summary>같은 이름의 그룹은 교체한다(Mac 판 mergeImported 와 같은 규칙).</summary>
    public int Import(List<SnippetGroup> groups)
    {
        foreach (var g in groups)
        {
            var index = Library.Data.Groups.FindIndex(x => x.Name == g.Name);
            if (index >= 0) Library.Data.Groups[index] = g;
            else Library.Data.Groups.Add(g);
        }
        Save();
        Library.Reload();
        return groups.Sum(g => g.Snippets.Count);
    }

    private void SeedStarterLibrary()
    {
        Library.Data.Groups.Add(new SnippetGroup
        {
            Name = Strings.S("starter.group"),
            Snippets =
            {
                new Snippet { Abbreviation = ";hello", Content = Strings.S("starter.hello"), Label = "Hello" },
                new Snippet { Abbreviation = ";date", Content = "%date:yyyy-MM-dd%", Label = "Today" },
                new Snippet { Abbreviation = ";sig", Content = "Best regards,\n%filltext:name=Your name%", Label = "Signature", AdaptCase = true },
            },
        });
        Save();
    }

    private void Quit()
    {
        _service.Dispose();
        _hotkey.Unregister();
        _hotkey.DestroyHandle();
        _watcher?.Dispose();
        _tray.Visible = false;
        _tray.Dispose();
        ExitThread();
    }
}

/// <summary>전역 단축키(RegisterHotKey)를 받는 보이지 않는 창.</summary>
internal sealed class HotkeyWindow : NativeWindow
{
    private const int Id = 1;
    private bool _registered;
    public event Action? Pressed;

    public HotkeyWindow() => CreateHandle(new CreateParams());

    public bool Register(uint modifiers, uint key)
    {
        _registered = Native.RegisterHotKey(Handle, Id, modifiers | Native.MOD_NOREPEAT, key);
        return _registered;
    }

    public void Unregister()
    {
        if (_registered) Native.UnregisterHotKey(Handle, Id);
        _registered = false;
    }

    protected override void WndProc(ref Message m)
    {
        if (m.Msg == Native.WM_HOTKEY && m.WParam == (IntPtr)Id) Pressed?.Invoke();
        base.WndProc(ref m);
    }
}

/// <summary>로그인할 때 시작(HKCU\...\Run). 관리자 권한이 필요 없다.</summary>
internal static class LoginItem
{
    private const string RunKey = @"Software\Microsoft\Windows\CurrentVersion\Run";
    private const string Name = "SnipKey";

    public static bool IsEnabled
    {
        get
        {
            using var key = Registry.CurrentUser.OpenSubKey(RunKey);
            return key?.GetValue(Name) is string;
        }
    }

    public static void Set(bool enabled)
    {
        using var key = Registry.CurrentUser.CreateSubKey(RunKey);
        if (enabled) key.SetValue(Name, $"\"{Environment.ProcessPath}\"");
        else key.DeleteValue(Name, throwOnMissingValue: false);
    }
}

/// <summary>아이콘을 코드로 그린다(바이너리 자산 없이). 꺼져 있으면 속이 빈 모양.</summary>
internal static class IconFactory
{
    private static readonly Dictionary<bool, Icon> Cache = new();

    public static Icon AppIcon(bool enabled)
    {
        if (Cache.TryGetValue(enabled, out var cached)) return cached;
        using var bmp = new Bitmap(32, 32);
        using (var g = Graphics.FromImage(bmp))
        {
            g.SmoothingMode = System.Drawing.Drawing2D.SmoothingMode.AntiAlias;
            var accent = Color.FromArgb(255, 122, 0);
            using var path = RoundedRect(new Rectangle(2, 2, 28, 28), 7);
            if (enabled) { using var fill = new SolidBrush(accent); g.FillPath(fill, path); }
            else { using var pen = new Pen(Color.Gray, 2.5f); g.DrawPath(pen, path); }
            var bolt = new[] { new Point(18, 5), new Point(9, 18), new Point(15, 18), new Point(13, 27), new Point(23, 13), new Point(17, 13) };
            using var brush = new SolidBrush(enabled ? Color.White : Color.Gray);
            g.FillPolygon(brush, bolt);
        }
        var icon = Icon.FromHandle(bmp.GetHicon());
        Cache[enabled] = icon;
        return icon;
    }

    private static System.Drawing.Drawing2D.GraphicsPath RoundedRect(Rectangle r, int radius)
    {
        var p = new System.Drawing.Drawing2D.GraphicsPath();
        var d = radius * 2;
        p.AddArc(r.X, r.Y, d, d, 180, 90);
        p.AddArc(r.Right - d, r.Y, d, d, 270, 90);
        p.AddArc(r.Right - d, r.Bottom - d, d, d, 0, 90);
        p.AddArc(r.X, r.Bottom - d, d, d, 90, 90);
        p.CloseFigure();
        return p;
    }
}
