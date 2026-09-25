namespace SnipKey.Core;

/// <summary>훅이 번역해 넘기는 키 한 번.</summary>
public abstract record KeyInput
{
    /// <summary>글자를 만든 키(스페이스·구두점 포함).</summary>
    public sealed record Character(string Text) : KeyInput;
    /// <summary>맨 백스페이스.</summary>
    public sealed record Backspace : KeyInput;
    /// <summary>
    /// 버퍼를 무효화하는 입력: Enter·Tab·Esc·화살표·Home/End·PgUp/PgDn·Delete,
    /// Ctrl/Win/Alt 조합, 마우스 클릭, 포커스된 창의 변경.
    /// </summary>
    public sealed record Invalidate : KeyInput;
}

/// <summary>엔진이 내린 결정.</summary>
public abstract record EngineAction
{
    public sealed record None : EngineAction;
    public sealed record Expand(Match Match) : EngineAction;
    public sealed record Undo(ExpansionUndo.Plan Plan) : EngineAction;
    public static readonly EngineAction Nothing = new None();
}

/// <summary>
/// 타이핑 버퍼와 매칭 결정. 화면·OS 에 의존하지 않아 어느 플랫폼에서든 테스트된다.
/// Windows 훅은 키를 <see cref="KeyInput"/> 으로 번역해 넘기기만 한다.
/// </summary>
public sealed class EngineCore
{
    public const int MaxBuffer = 64;

    private readonly List<string> _buffer = new();
    private ExpansionUndo.Plan? _pendingUndo;

    public Matcher Matcher { get; set; } = Matcher.Empty;
    public bool Enabled { get; set; } = true;
    public bool UndoWithBackspace { get; set; } = true;

    public IReadOnlyList<string> Buffer => _buffer;
    public bool HasPendingUndo => _pendingUndo is not null;

    public void Clear() => _buffer.Clear();

    /// <summary>
    /// 주입이 끝난 뒤, 매치 이후 사용자 입력이 전혀 없었을 때만 호출한다(호출자의 책임).
    /// 그 뒤 첫 입력이 맨 백스페이스면 되돌리고, 다른 무엇이든 오면 기회는 사라진다.
    /// </summary>
    public void ArmUndo(ExpansionUndo.Plan plan) => _pendingUndo = plan;

    public void DisarmUndo() => _pendingUndo = null;

    public EngineAction Handle(KeyInput input)
    {
        if (_pendingUndo is { } undo)
        {
            _pendingUndo = null;
            if (input is KeyInput.Backspace && UndoWithBackspace)
            {
                _buffer.Clear();
                return new EngineAction.Undo(undo);
            }
        }

        if (!Enabled)
        {
            _buffer.Clear();
            return EngineAction.Nothing;
        }

        switch (input)
        {
            case KeyInput.Backspace:
                if (_buffer.Count > 0) _buffer.RemoveAt(_buffer.Count - 1);
                return EngineAction.Nothing;

            case KeyInput.Invalidate:
                _buffer.Clear();
                return EngineAction.Nothing;

            case KeyInput.Character c when c.Text.Length > 0:
                _buffer.AddRange(TextElements.Split(c.Text));
                if (_buffer.Count > MaxBuffer) _buffer.RemoveRange(0, _buffer.Count - MaxBuffer);
                if (Matcher.Find(_buffer) is { } match)
                {
                    _buffer.Clear();
                    return new EngineAction.Expand(match);
                }
                return EngineAction.Nothing;

            default:
                return EngineAction.Nothing;
        }
    }
}
