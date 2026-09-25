using SnipKey.Core;

namespace SnipKey.Windows;

/// <summary>채우기 필드를 묻는 작은 창. 취소하면 null(친 약어는 그대로 남는다).</summary>
internal sealed class FillInForm : Form
{
    private readonly Dictionary<int, Func<string>> _readers = new();

    private FillInForm(string title, IReadOnlyList<FillField> fields)
    {
        Text = Strings.S("fill.title", title);
        FormBorderStyle = FormBorderStyle.FixedDialog;
        MaximizeBox = MinimizeBox = false;
        ShowInTaskbar = false;
        TopMost = true;
        StartPosition = FormStartPosition.CenterScreen;
        AutoSize = true;
        AutoSizeMode = AutoSizeMode.GrowAndShrink;
        Padding = new Padding(12);
        Font = SystemFonts.MessageBoxFont ?? Font;

        var layout = new TableLayoutPanel
        {
            ColumnCount = 2,
            AutoSize = true,
            Dock = DockStyle.Fill,
        };
        layout.ColumnStyles.Add(new ColumnStyle(SizeType.AutoSize));
        layout.ColumnStyles.Add(new ColumnStyle(SizeType.Absolute, 320));

        Control? first = null;
        foreach (var field in fields)
        {
            Control input;
            switch (field.Kind)
            {
                case FillKind.Part:
                    var check = new CheckBox
                    {
                        Text = Strings.S("fill.include", field.Name),
                        Checked = !field.DefaultValue.Equals("no", StringComparison.OrdinalIgnoreCase),
                        AutoSize = true,
                    };
                    _readers[field.Id] = () => check.Checked ? "yes" : "no";
                    layout.Controls.Add(new Label());
                    layout.Controls.Add(check);
                    first ??= check;
                    continue;
                case FillKind.Popup:
                    var combo = new ComboBox { DropDownStyle = ComboBoxStyle.DropDownList, Width = 320 };
                    combo.Items.AddRange(field.Options.Cast<object>().ToArray());
                    // 기본값이 선택지에 없으면 목록 맨 앞에 넣는다(비어 보이는 선택 상자를 만들지 않는다).
                    if (field.DefaultValue.Length > 0 && !field.Options.Contains(field.DefaultValue)) combo.Items.Insert(0, field.DefaultValue);
                    combo.SelectedItem = field.DefaultValue.Length > 0 ? field.DefaultValue : combo.Items.Count > 0 ? combo.Items[0] : null;
                    _readers[field.Id] = () => combo.SelectedItem?.ToString() ?? "";
                    input = combo;
                    break;
                case FillKind.Area:
                    var area = new TextBox { Multiline = true, AcceptsReturn = true, Height = 90, Width = 320, ScrollBars = ScrollBars.Vertical, Text = field.DefaultValue };
                    _readers[field.Id] = () => area.Text;
                    input = area;
                    break;
                default:
                    var box = new TextBox { Width = 320, Text = field.DefaultValue };
                    _readers[field.Id] = () => box.Text;
                    input = box;
                    break;
            }
            layout.Controls.Add(new Label { Text = field.Name.Length > 0 ? field.Name : "…", AutoSize = true, Anchor = AnchorStyles.Left | AnchorStyles.Top, Padding = new Padding(0, 6, 8, 0) });
            layout.Controls.Add(input);
            first ??= input;
        }

        var ok = new Button { Text = Strings.S("fill.insert"), DialogResult = DialogResult.OK, AutoSize = true };
        var cancel = new Button { Text = Strings.S("fill.cancel"), DialogResult = DialogResult.Cancel, AutoSize = true };
        var buttons = new FlowLayoutPanel { FlowDirection = FlowDirection.RightToLeft, AutoSize = true, Dock = DockStyle.Fill, Margin = new Padding(0, 8, 0, 0) };
        buttons.Controls.Add(ok);
        buttons.Controls.Add(cancel);
        layout.Controls.Add(new Label());
        layout.Controls.Add(buttons);

        AcceptButton = ok;
        CancelButton = cancel;
        Controls.Add(layout);
        // 우리 프로세스는 입력을 받은 적이 없어 그냥 Activate() 하면 전경 잠금에 막힌다.
        // 그러면 사용자가 친 값이 원래 앱으로 가 버린다(그 경우 확장은 호출자가 버린다).
        Shown += (_, _) => { Native.ForceForeground(Handle); Activate(); first?.Focus(); };
    }

    /// <returns>필드 번호 → 값, 또는 취소 시 null.</returns>
    public static Dictionary<int, string>? Ask(string title, IReadOnlyList<FillField> fields)
    {
        using var form = new FillInForm(title, fields);
        return form.ShowDialog() == DialogResult.OK
            ? form._readers.ToDictionary(kv => kv.Key, kv => kv.Value())
            : null;
    }
}

/// <summary>검색 팔레트: 어느 프로그램에서든 단축키로 불러 약어를 잊어도 스니펫을 넣는다.</summary>
internal sealed class SearchPalette : Form
{
    private const int MaxResults = 30;
    private readonly Library _library;
    private readonly Action<Snippet, IntPtr> _choose;
    private readonly TextBox _query = new() { Dock = DockStyle.Top };
    private readonly ListBox _results = new() { Dock = DockStyle.Fill, IntegralHeight = false };
    private List<SearchHit> _hits = new();
    private IntPtr _target;

    public SearchPalette(Library library, Action<Snippet, IntPtr> choose)
    {
        _library = library;
        _choose = choose;
        FormBorderStyle = FormBorderStyle.FixedToolWindow;
        ShowInTaskbar = false;
        TopMost = true;
        StartPosition = FormStartPosition.CenterScreen;
        Size = new Size(560, 380);
        Text = Strings.S("tray.search", "").TrimEnd(' ', '(', ')');
        Font = new Font(SystemFonts.MessageBoxFont?.FontFamily ?? FontFamily.GenericSansSerif, 11f);
        _query.PlaceholderText = Strings.S("palette.placeholder");
        _results.FormattingEnabled = true; // 없으면 Format 이 불리지 않아 형식 이름이 보인다
        _results.Format += (_, e) =>
        {
            if (e.ListItem is SearchHit h)
                e.Value = $"{h.Snippet.Abbreviation}    {h.Snippet.DisplayTitle}    — {Preview(h.Snippet.Content)}";
        };
        Controls.Add(_results);
        Controls.Add(_query);

        _query.TextChanged += (_, _) => Refresh(_query.Text);
        _query.KeyDown += OnKeyDown;
        _results.KeyDown += OnKeyDown;
        _results.DoubleClick += (_, _) => Choose();
        // 다른 곳을 클릭하면 닫는다 — 팔레트가 떠 있는 채로 남지 않게.
        Deactivate += (_, _) => Hide();
    }

    private static string Preview(string content)
    {
        var line = content.Replace("\r", " ").Replace("\n", " ");
        return line.Length > 60 ? line[..60] + "…" : line;
    }

    public void ShowFor(IntPtr target)
    {
        _target = target;
        _query.Text = "";
        Refresh("");
        Show();
        Native.ForceForeground(Handle);
        Activate();
        _query.Focus();
    }

    private void Refresh(string query)
    {
        _hits = query.Trim().Length == 0
            // 빈 검색어: 최근에 고친 스니펫부터.
            ? _library.Data.Groups.Where(g => g.Enabled)
                .SelectMany(g => g.Snippets.Where(s => s.Enabled && s.Abbreviation.Length > 0).Select(s => new SearchHit(s, g.Id, g.Name, 0)))
                .OrderByDescending(h => h.Snippet.ModifiedAt).Take(MaxResults).ToList()
            : SnippetSearch.Run(query, _library.Data.Groups, includeDisabled: false, limit: MaxResults);
        _results.DataSource = _hits;
        if (_hits.Count > 0) _results.SelectedIndex = 0;
    }

    private void OnKeyDown(object? sender, KeyEventArgs e)
    {
        switch (e.KeyCode)
        {
            case Keys.Escape: Hide(); e.Handled = true; break;
            case Keys.Enter: Choose(); e.Handled = e.SuppressKeyPress = true; break;
            case Keys.Down when sender == _query && _results.SelectedIndex < _hits.Count - 1:
                _results.SelectedIndex++; e.Handled = true; break;
            case Keys.Up when sender == _query && _results.SelectedIndex > 0:
                _results.SelectedIndex--; e.Handled = true; break;
        }
    }

    private void Choose()
    {
        if (_results.SelectedItem is not SearchHit hit) return;
        Hide();
        _choose(hit.Snippet, _target);
    }

    protected override void OnFormClosing(FormClosingEventArgs e)
    {
        // 창을 재사용한다 — 닫지 말고 숨긴다.
        if (e.CloseReason == CloseReason.UserClosing) { e.Cancel = true; Hide(); }
        base.OnFormClosing(e);
    }
}
