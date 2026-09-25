using System.Globalization;
using SnipKey.Core;

namespace SnipKey.Windows;

internal static class Program
{
    [STAThread]
    private static int Main(string[] args)
    {
        if (args.Contains("--selfcheck")) return SelfCheck();

        // 두 개가 동시에 돌면 같은 약어를 두 번 확장한다.
        using var single = new Mutex(initiallyOwned: true, @"Local\SnipKey.Windows.SingleInstance", out var first);
        if (!first) return 0;

        ApplicationConfiguration.Initialize();
        Application.SetUnhandledExceptionMode(UnhandledExceptionMode.CatchException);
        Application.ThreadException += (_, e) => Log.Write("unhandled: " + e.Exception);
        Application.Run(new App());
        return 0;
    }

    /// <summary>
    /// 배포된 exe 가 실제로 뜨고 핵심 경로가 도는지 CI 가 확인한다(창·훅 없이).
    /// macOS 판 --selfcheck 와 같은 목적: 빌드는 초록인데 설치본만 죽는 부류를 잡는다.
    /// </summary>
    private static int SelfCheck()
    {
        var failures = new List<string>(Strings.MissingKeys());
        var tokens = MacroParser.Parse("Hi %filltext:name=who:default=you%, %date:yyyy%");
        var text = MacroParser.Render(tokens, now: new DateTime(2026, 1, 2), culture: CultureInfo.InvariantCulture).Text;
        if (text != "Hi you, 2026") failures.Add("render: " + text);
        if (IconFactory.AppIcon(true) is null) failures.Add("icon");
        foreach (var f in failures) Console.Error.WriteLine("selfcheck: " + f);
        Console.WriteLine(failures.Count == 0 ? "selfcheck ok" : $"selfcheck failed ({failures.Count})");
        return failures.Count == 0 ? 0 : 1;
    }
}
