using System.Runtime.InteropServices;
using System.Text;
using SnipKey.Core;

namespace SnipKey.Windows;

/// <summary>
/// 저수준 키보드·마우스 훅. 키를 <see cref="KeyInput"/> 으로 번역해 넘기기만 하고,
/// 키를 삼키지 않는다(macOS 판의 listen-only 탭과 같다).
///
/// 콜백은 반드시 빨리 끝나야 한다. Windows 는 LowLevelHooksTimeout(최대 1초)을 넘긴 훅을
/// 알림 없이 제거한다. 그래서 훅은 **전용 스레드**의 메시지 루프에서 돌고, 여기서는 키를
/// 번역해 이벤트로 넘기기만 한다. UI 스레드가 클립보드·파일 저장으로 잠시 막혀도 시스템
/// 전체의 키 입력이 멈추지 않는다. 이벤트는 이 훅 스레드에서 발생한다.
/// </summary>
internal sealed class KeyboardHook : IDisposable
{
    /// <summary>우리가 SendInput 으로 보낸 이벤트 표식("SNIP"). 훅에서 보면 걸러 낸다.</summary>
    public static readonly IntPtr Marker = new(0x534E4950);

    private const uint LLKHF_INJECTED = 0x10;

    // 대리자를 필드로 붙잡아 둔다 — 지역 변수면 GC 가 수거해 훅 호출이 프로세스를 죽인다.
    private readonly Native.LowLevelProc _keyboardProc;
    private readonly Native.LowLevelProc _mouseProc;
    private IntPtr _keyboardHook;
    private IntPtr _mouseHook;
    private readonly byte[] _keyState = new byte[256];
    private readonly StringBuilder _chars = new(8);

    private Thread? _thread;
    private readonly InputClock _clock;

    /// <summary>번역된 키. 인자: 입력, 키를 받은 전경 창, 이 입력의 순번(<see cref="InputClock"/>).</summary>
    public event Action<KeyInput, IntPtr, long>? Key;

    public KeyboardHook(InputClock clock)
    {
        _clock = clock;
        _keyboardProc = KeyboardProc;
        _mouseProc = MouseProc;
    }

    public void Start()
    {
        if (_thread is not null) return;
        _thread = new Thread(() =>
        {
            var module = Native.GetModuleHandle(null);
            _keyboardHook = Native.SetWindowsHookEx(Native.WH_KEYBOARD_LL, _keyboardProc, module, 0);
            _mouseHook = Native.SetWindowsHookEx(Native.WH_MOUSE_LL, _mouseProc, module, 0);
            if (_keyboardHook == IntPtr.Zero) Log.Write($"keyboard hook failed: {Marshal.GetLastWin32Error()}");
            else Log.Write("hooks installed");
            Application.Run(); // 훅 호출은 이 스레드의 메시지 루프로 배달된다
        })
        { IsBackground = true, Name = "SnipKey hooks" };
        _thread.SetApartmentState(ApartmentState.STA);
        _thread.Start();
    }

    public void Stop()
    {
        if (_keyboardHook != IntPtr.Zero) Native.UnhookWindowsHookEx(_keyboardHook);
        if (_mouseHook != IntPtr.Zero) Native.UnhookWindowsHookEx(_mouseHook);
        _keyboardHook = _mouseHook = IntPtr.Zero;
    }

    public void Dispose() => Stop();

    private IntPtr KeyboardProc(int nCode, IntPtr wParam, IntPtr lParam)
    {
        if (nCode >= 0)
        {
            var msg = (int)wParam;
            if (msg == Native.WM_KEYDOWN || msg == Native.WM_SYSKEYDOWN)
            {
                var info = Marshal.PtrToStructure<Native.KBDLLHOOKSTRUCT>(lParam);
                // 우리 자신의 합성 입력은 무시한다. 다른 프로그램의 합성 입력(원격 데스크톱 등)은
                // 사용자 입력으로 본다.
                if (!((info.flags & LLKHF_INJECTED) != 0 && info.dwExtraInfo == Marker))
                {
                    try { Handle(info); }
                    catch (Exception e) when (e is not OutOfMemoryException) { Log.Write("hook error: " + e.Message); }
                }
            }
        }
        return Native.CallNextHookEx(_keyboardHook, nCode, wParam, lParam);
    }

    private IntPtr MouseProc(int nCode, IntPtr wParam, IntPtr lParam)
    {
        if (nCode >= 0)
        {
            var msg = (int)wParam;
            if (msg is Native.WM_LBUTTONDOWN or Native.WM_RBUTTONDOWN or Native.WM_MBUTTONDOWN)
            {
                // 클릭은 커서를 옮긴다 — 뒤이어 나갈 백스페이스가 엉뚱한 곳을 지우지 않게.
                // 콜백 밖으로 예외가 새면 Application.ThreadException 도 못 잡고 프로세스가 죽는다.
                try
                {
                    var seq = _clock.Mark();
                    Key?.Invoke(new KeyInput.Invalidate(), Native.GetForegroundWindow(), seq);
                }
                catch (Exception e) when (e is not OutOfMemoryException) { Log.Write("mouse hook error: " + e.Message); }
            }
        }
        return Native.CallNextHookEx(_mouseHook, nCode, wParam, lParam);
    }

    private void Handle(Native.KBDLLHOOKSTRUCT info)
    {
        var seq = _clock.Mark();
        void Emit(KeyInput input, IntPtr fg) => Key?.Invoke(input, fg, seq);
        var vk = (ushort)info.vkCode;
        var foreground = Native.GetForegroundWindow();

        switch (vk)
        {
            case Native.VK_SHIFT or Native.VK_LSHIFT or Native.VK_RSHIFT or Native.VK_CONTROL or Native.VK_LCONTROL
                or Native.VK_RCONTROL or Native.VK_MENU or Native.VK_LMENU or Native.VK_RMENU or Native.VK_CAPITAL
                or Native.VK_LWIN or Native.VK_RWIN:
                return; // 수정자 키 자체는 아무 글자도 만들지 않는다.
        }

        var ctrl = Native.IsKeyDown(Native.VK_CONTROL);
        var alt = Native.IsKeyDown(Native.VK_MENU);
        var win = Native.IsKeyDown(Native.VK_LWIN) || Native.IsKeyDown(Native.VK_RWIN);
        var altGr = ctrl && alt; // 유럽 배열의 AltGr 는 Ctrl+Alt 로 보인다 — 글자를 만든다.

        if (win || (ctrl && !altGr) || (alt && !altGr))
        {
            Emit(new KeyInput.Invalidate(), foreground);
            return;
        }

        switch (vk)
        {
            case Native.VK_BACK:
                Emit(new KeyInput.Backspace(), foreground);
                return;
            // Return·Tab 은 앱이 이미 받아 무언가를 했다(메시지 전송, 포커스 이동) —
            // 맨몸 약어의 종결자로 쓰지 않는다(CONTRIBUTING.md 의 의도된 동작).
            case Native.VK_RETURN or Native.VK_TAB or Native.VK_ESCAPE or Native.VK_LEFT or Native.VK_RIGHT
                or Native.VK_UP or Native.VK_DOWN or Native.VK_HOME or Native.VK_END or Native.VK_PRIOR
                or Native.VK_NEXT or Native.VK_DELETE or Native.VK_INSERT:
                Emit(new KeyInput.Invalidate(), foreground);
                return;
        }

        var text = Translate(vk, info.scanCode, foreground);
        if (text is null) return;
        Emit(new KeyInput.Character(text), foreground);
    }

    /// <summary>
    /// 전경 창의 키보드 배열로 키를 글자로 바꾼다. wFlags=4 는 "커널 키보드 상태를 바꾸지 말라"
    /// (Windows 10 1607+) — 이게 없으면 우리가 호출하는 것만으로 데드 키(악센트) 입력이 깨진다.
    /// </summary>
    private string? Translate(ushort vk, uint scanCode, IntPtr foreground)
    {
        Array.Clear(_keyState);
        if (Native.IsKeyDown(Native.VK_SHIFT)) _keyState[Native.VK_SHIFT] = 0x80;
        if (Native.IsKeyDown(Native.VK_CONTROL)) _keyState[Native.VK_CONTROL] = 0x80;
        if (Native.IsKeyDown(Native.VK_MENU)) _keyState[Native.VK_MENU] = 0x80;
        if ((Native.GetKeyState(Native.VK_CAPITAL) & 1) != 0) _keyState[Native.VK_CAPITAL] = 0x01;

        var thread = Native.GetWindowThreadProcessId(foreground, out _);
        var layout = Native.GetKeyboardLayout(thread);
        _chars.Clear();
        var n = Native.ToUnicodeEx(vk, scanCode, _keyState, _chars, _chars.Capacity, 4, layout);
        if (n <= 0) return null; // 0: 글자 없음, 음수: 데드 키(다음 키와 합쳐진다)
        var s = _chars.ToString(0, Math.Min(n, _chars.Length));
        return s.Any(char.IsControl) ? null : s;
    }

    /// <summary>
    /// 전경 창의 IME 가 조합 모드(한글·일본어 가나·중국어 등 원어 입력)인가. 이때 훅이 보는
    /// 키는 물리 라틴 글자이지만 화면에는 조합 중인 글자가 있어 백스페이스 수를 셀 수 없다 —
    /// 확장하지 않는다. 다른 프로세스 창에 보내는 메시지라 짧은 타임아웃을 쓴다.
    /// UI 스레드에서 확장 직전에만 부른다(훅 안에서 부르지 않는다).
    /// </summary>
    public static bool IsImeComposing(IntPtr foreground)
    {
        var ime = Native.ImmGetDefaultIMEWnd(foreground);
        if (ime == IntPtr.Zero) return false;
        if (Native.SendMessageTimeout(ime, Native.WM_IME_CONTROL, Native.IMC_GETOPENSTATUS, IntPtr.Zero,
                Native.SMTO_ABORTIFHUNG, 50, out var open) == IntPtr.Zero) return false;
        if (open == IntPtr.Zero) return false;
        if (Native.SendMessageTimeout(ime, Native.WM_IME_CONTROL, Native.IMC_GETCONVERSIONMODE, IntPtr.Zero,
                Native.SMTO_ABORTIFHUNG, 50, out var mode) == IntPtr.Zero) return true; // 열려 있는데 모드를 모르면 안전한 쪽
        return (mode.ToInt64() & Native.IME_CMODE_NATIVE) != 0;
    }
}
