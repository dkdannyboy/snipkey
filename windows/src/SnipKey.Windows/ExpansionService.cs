using System.Diagnostics;
using SnipKey.Core;

namespace SnipKey.Windows;

/// <summary>
/// 훅 → 엔진 → (채우기 창) → 주입의 흐름을 잇는다. 훅 이벤트는 훅 스레드에서 오므로
/// UI 스레드로 넘겨(BeginInvoke, 순서 보존) 처리한다. macOS 판 ExpansionEngine 과 같은
/// 안전 규칙을 따른다:
///   · 매치 이후 사용자 입력이 하나라도 있으면 확장을 버린다(입력 가드).
///   · 되돌릴 수 없는 키가 나가기 직전에 포커스가 그대로인지 다시 본다.
///   · 되돌리기는 매치 이후 입력이 전혀 없었을 때만 무장한다.
/// </summary>
internal sealed class ExpansionService : IDisposable
{
    private readonly Control _ui;
    private readonly Library _library;
    private readonly Func<LocalSettings> _settings;
    private readonly InputClock _clock = new();
    private readonly KeyboardHook _hook;
    private readonly Injector _injector;
    private readonly EngineCore _engine = new();
    private readonly int _selfPid = Environment.ProcessId;
    private readonly bool _selfElevated = Native.IsElevated((uint)Environment.ProcessId);

    private IntPtr _lastForeground;
    private string? _foregroundExe;
    private bool _fillInOpen;
    /// <summary>채우기 창이 열려 있는 동안 '다른' 창으로 간 키가 있었는가(포커스를 못 가져온 경우).</summary>
    private bool _keysLeakedDuringFillIn;
    private readonly HashSet<string> _warnedElevated = new(StringComparer.OrdinalIgnoreCase);

    /// <summary>마지막으로 앞에 있던 '다른' 프로그램(트레이 메뉴의 "~에서 확장 안 함"·검색 대상).</summary>
    public (string Exe, string Name, IntPtr Window)? LastExternalApp { get; private set; }
    public int ExpansionCount { get; private set; }
    public event Action<string>? Notify;

    public ExpansionService(Control ui, Library library, Func<LocalSettings> settings)
    {
        _ui = ui;
        _library = library;
        _settings = settings;
        _hook = new KeyboardHook(_clock);
        _injector = new Injector(settings);
        // 훅 스레드 → UI 스레드. BeginInvoke 는 순서를 지키므로 버퍼가 뒤섞이지 않는다.
        _hook.Key += (input, fg, seq) => _ui.BeginInvoke(() => OnKey(input, fg, seq));
        _library.Changed += () => _engine.Matcher = _library.Matcher;
        _engine.Matcher = _library.Matcher;
    }

    public void Start() => _hook.Start();

    public void Dispose()
    {
        _hook.Dispose();
        _injector.Dispose();
    }

    // ---- 키 (UI 스레드) ----

    private void OnKey(KeyInput input, IntPtr foreground, long seq)
    {
        var ours = IsOurWindow(foreground);
        if (_fillInOpen && !ours && input is not KeyInput.Invalidate) _keysLeakedDuringFillIn = true;

        if (foreground != _lastForeground)
        {
            // 창이 바뀌면 버퍼를 비운다. 친 약어가 다른 창으로 넘어가 확장되면 안 된다.
            _lastForeground = foreground;
            _engine.Clear();
            _engine.DisarmUndo();
            if (!ours) UpdateForeground(foreground);
        }

        var settings = _settings();
        _engine.UndoWithBackspace = settings.UndoWithBackspace;
        _engine.Enabled = settings.ExpansionEnabled && !_fillInOpen && !ours && !settings.IsExcluded(_foregroundExe);

        switch (_engine.Handle(input))
        {
            case EngineAction.Expand e:
                // 매치를 일으킨 바로 그 키의 순번으로 무장한다 — 그 뒤의 입력은 전부 걸린다.
                Expand(e.Match, foreground, seq);
                break;
            case EngineAction.Undo u:
                Undo(u.Plan, foreground, seq);
                break;
        }
    }

    private bool IsOurWindow(IntPtr hwnd)
    {
        Native.GetWindowThreadProcessId(hwnd, out var pid);
        return pid == _selfPid;
    }

    private void UpdateForeground(IntPtr hwnd)
    {
        Native.GetWindowThreadProcessId(hwnd, out var pid);
        var path = Native.ProcessPath(pid);
        _foregroundExe = path is null ? null : Path.GetFileName(path).ToLowerInvariant();
        if (_foregroundExe is null) return;
        var name = _foregroundExe;
        try
        {
            if (FileVersionInfo.GetVersionInfo(path!).FileDescription is { Length: > 0 } d) name = d;
        }
        catch (Exception e) when (e is FileNotFoundException or UnauthorizedAccessException or IOException) { }
        LastExternalApp = (_foregroundExe, name, hwnd);
    }

    // ---- 확장 ----

    private void Expand(Match match, IntPtr target, long guard)
    {
        if (match.Backspaces > 0 && KeyboardHook.IsImeComposing(target))
        {
            // IME 조합 중에는 화면 글자 수를 셀 수 없다(한글·가나 등).
            Log.Write("skipped — IME is composing");
            return;
        }
        if (!CanTypeInto(target)) return;

        var snippet = match.Snippet;
        var resolved = MacroParser.ResolveNested(snippet.Content, a => _library.SnippetFor(a)?.Content);
        var tokens = MacroParser.Parse(resolved);
        Func<string, string> adapt = snippet.AdaptCase
            ? t => CaseAdapter.Adapt(t, match.Typed, snippet.Abbreviation)
            : t => t;

        if (!MacroParser.HasFillIns(tokens))
        {
            Inject(tokens, new Dictionary<int, string>(), adapt, match, target, guard);
            return;
        }

        // 채우기 창을 띄우기 전에 한 번 더 본다: 그사이 대상 창에 입력했다면 버린다.
        // (창에 값을 치기 시작하면 이 정보는 더 이상 보이지 않는다.)
        Delay(120, () =>
        {
            if (match.Backspaces > 0 && _clock.InputSince(guard)) { Log.Write("cancelled before fill-in"); return; }
            Dictionary<int, string>? values;
            _fillInOpen = true;
            _keysLeakedDuringFillIn = false;
            try { values = FillInForm.Ask(snippet.DisplayTitle, MacroParser.FillFields(tokens)); }
            finally { _fillInOpen = false; }
            // 창이 닫히는 이 순간 새로 무장한다. 창에 친 값들은 이보다 앞선 순번이다.
            var afterPanel = _clock.Current;
            Native.SetForegroundWindow(target);
            if (values is null) return; // 취소 — 친 약어를 그대로 둔다
            if (_keysLeakedDuringFillIn && match.Backspaces > 0)
            {
                // 채우기 창이 포커스를 못 가져와 사용자의 입력이 대상 앱으로 갔다. 이제 백스페이스를
                // 보내면 약어가 아니라 그 입력을 지운다 — 확장을 버린다.
                Log.Write("cancelled — keys went to another window while the fill-in form was open");
                return;
            }
            Delay(250, () => Inject(tokens, values, adapt, match, target, afterPanel));
        });
    }

    private void Inject(List<MacroToken> tokens, Dictionary<int, string> values, Func<string, string> adapt,
        Match match, IntPtr target, long guard)
    {
        // 클립보드는 매크로가 쓸 때만 읽는다 — 지연 렌더링하는 앱(엑셀·원격 데스크톱)은 몇 초씩 막힌다.
        var clipboardText = "";
        if (tokens.Any(t => t is MacroToken.Clipboard))
        {
            try { if (Clipboard.ContainsText()) clipboardText = Clipboard.GetText(); }
            catch (System.Runtime.InteropServices.ExternalException) { }
        }

        var result = MacroParser.Render(tokens, values, () => clipboardText);
        var text = adapt(result.Text);
        var cursor = result.CursorOffsetFromEnd;
        if (match.Terminator.Length > 0)
        {
            text += match.Terminator;
            if (cursor > 0) cursor += TextElements.Count(match.Terminator);
        }
        var undoPlan = ExpansionUndo.For(text, match.Typed, match.Terminator, cursor, result.TrailingKeys);

        _injector.Enqueue(new InjectionJob(
            match.Backspaces, text, cursor, result.TrailingKeys, target,
            () => _clock.InputSince(guard),
            _settings().PlaySound,
            done => _ui.BeginInvoke(() =>
            {
                if (!done) return;
                ExpansionCount++;
                if (undoPlan is not null && !_clock.InputSince(guard)) _engine.ArmUndo(undoPlan);
            })));
    }

    private void Undo(ExpansionUndo.Plan plan, IntPtr target, long guard)
    {
        Log.Write($"undo expansion (backspaces={plan.Backspaces})");
        _injector.Enqueue(new InjectionJob(plan.Backspaces, plan.Restore, 0, Array.Empty<string>(), target,
            () => _clock.InputSince(guard), false, null));
    }

    /// <summary>검색 팔레트에서 고른 스니펫. 아무것도 치지 않았으므로 지우지 않는다.</summary>
    public void ExpandFromSearch(Snippet snippet, IntPtr target)
    {
        if (target == IntPtr.Zero) target = LastExternalApp?.Window ?? IntPtr.Zero;
        if (target == IntPtr.Zero) return;
        Native.SetForegroundWindow(target);
        var match = new Match(snippet, 0, "", "");
        Delay(250, () => Expand(match, target, _clock.Current));
    }

    private bool CanTypeInto(IntPtr target)
    {
        Native.GetWindowThreadProcessId(target, out var pid);
        if (_selfElevated || !Native.IsElevated(pid)) return true;
        var name = _foregroundExe ?? "?";
        if (_warnedElevated.Add(name)) Notify?.Invoke(Strings.S("notify.elevated", name));
        Log.Write("skipped — target is elevated");
        return false;
    }

    private static void Delay(int ms, Action action)
    {
        var t = new System.Windows.Forms.Timer { Interval = ms };
        t.Tick += (_, _) => { t.Dispose(); action(); };
        t.Start();
    }
}
