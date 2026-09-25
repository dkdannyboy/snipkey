using System.Diagnostics;
using SnipKey.Core;

namespace SnipKey.Windows;

/// <summary>스니펫 관리 창: 그룹 · 스니펫 목록 · 편집기, 그리고 설정 탭.</summary>
internal sealed class ManagerForm : Form
{
    private readonly App _app;
    private Library Library => _app.Library;

    private readonly Label _banner = new() { Dock = DockStyle.Top, AutoSize = false, Height = 0, BackColor = Color.FromArgb(255, 244, 214), Padding = new Padding(8, 6, 8, 6) };
    private readonly TabControl _tabs = new() { Dock = DockStyle.Fill };

    // 스니펫 탭
    private readonly ListBox _groups = new() { Dock = DockStyle.Fill, IntegralHeight = false };
    private readonly CheckBox _groupEnabled = new() { Dock = DockStyle.Bottom, AutoSize = true };
    private readonly TextBox _search = new() { Dock = DockStyle.Top };
    private readonly ListView _list = new() { Dock = DockStyle.Fill, View = View.Details, FullRowSelect = true, HideSelection = false, MultiSelect = false };
    private readonly TextBox _abbreviation = new() { Dock = DockStyle.Top };
    private readonly TextBox _label = new() { Dock = DockStyle.Top };
    private readonly TextBox _content = new() { Dock = DockStyle.Fill, Multiline = true, AcceptsReturn = true, AcceptsTab = true, ScrollBars = ScrollBars.Vertical };
    private readonly CheckBox _enabled = new() { AutoSize = true };
    private readonly CheckBox _caseSensitive = new() { AutoSize = true };
    private readonly CheckBox _adaptCase = new() { AutoSize = true };
    private readonly Label _conflict = new() { Dock = DockStyle.Top, ForeColor = Color.DarkOrange, AutoSize = true };
    private readonly Label _preview = new() { Dock = DockStyle.Bottom, Height = 70, BorderStyle = BorderStyle.FixedSingle, Padding = new Padding(4) };
    private readonly Panel _editor = new() { Dock = DockStyle.Fill, Padding = new Padding(8) };
    private readonly Label _editorEmpty = new() { Dock = DockStyle.Fill, TextAlign = ContentAlignment.MiddleCenter };

    private readonly System.Windows.Forms.Timer _saveTimer = new() { Interval = 600 };
    private SnippetGroup? _group;
    private Snippet? _snippet;
    private bool _loading;

    public ManagerForm(App app)
    {
        _app = app;
        Text = "SnipKey";
        Size = new Size(1040, 660);
        MinimumSize = new Size(820, 480);
        StartPosition = FormStartPosition.CenterScreen;
        Font = SystemFonts.MessageBoxFont ?? Font;
        Icon = IconFactory.AppIcon(true);

        _tabs.TabPages.Add(BuildSnippetsTab());
        _tabs.TabPages.Add(new SettingsPage(app) { Text = Strings.S("tab.settings") });
        Controls.Add(_tabs);
        Controls.Add(_banner);

        _saveTimer.Tick += (_, _) => { _saveTimer.Stop(); _app.Save(); };
        Library.Reloaded += OnLibraryReloaded;
        _app.StatusChanged += UpdateBanner;
        FormClosed += (_, _) =>
        {
            FlushPendingSave();
            Library.Reloaded -= OnLibraryReloaded;
            _app.StatusChanged -= UpdateBanner;
        };
        ReloadGroups();
        UpdateBanner();
    }

    public void ShowSettings() => _tabs.SelectedIndex = 1;

    private void OnLibraryReloaded()
    {
        // 들고 있던 스니펫 객체는 버려졌다. 같은 id 로 다시 찾는다.
        var groupId = _group?.Id;
        var snippetId = _snippet?.Id;
        ReloadGroups(groupId, snippetId);
    }

    private void FlushPendingSave()
    {
        if (!_saveTimer.Enabled) return;
        _saveTimer.Stop();
        _app.Save();
    }

    private void ScheduleSave()
    {
        _saveTimer.Stop();
        _saveTimer.Start();
    }

    private void UpdateBanner()
    {
        var text = _app.StatusMessage;
        _banner.Text = text ?? "";
        _banner.Height = string.IsNullOrEmpty(text) ? 0 : 44;
    }

    // ---- 스니펫 탭 ----

    private TabPage BuildSnippetsTab()
    {
        var page = new TabPage(Strings.S("tab.snippets"));

        // 왼쪽: 그룹
        var groupButtons = new FlowLayoutPanel { Dock = DockStyle.Bottom, AutoSize = true };
        groupButtons.Controls.Add(Button("group.add", AddGroup));
        groupButtons.Controls.Add(Button("group.rename", RenameGroup));
        groupButtons.Controls.Add(Button("group.delete", DeleteGroup));
        _groupEnabled.Text = Strings.S("group.enabled");
        _groupEnabled.CheckedChanged += (_, _) =>
        {
            if (_loading || _group is null) return;
            _group.Enabled = _groupEnabled.Checked;
            ScheduleSave();
            _groups.Refresh();
        };
        var left = new Panel { Dock = DockStyle.Fill, Padding = new Padding(6) };
        left.Controls.Add(_groups);
        left.Controls.Add(new Label { Text = Strings.S("groups"), Dock = DockStyle.Top, AutoSize = true });
        left.Controls.Add(_groupEnabled);
        left.Controls.Add(groupButtons);
        _groups.FormattingEnabled = true;
        _groups.Format += (_, e) => { if (e.ListItem is SnippetGroup g) e.Value = g.Enabled ? g.Name : $"{g.Name}  (off)"; };
        _groups.SelectedIndexChanged += (_, _) => { if (!_loading) SelectGroup(_groups.SelectedItem as SnippetGroup); };

        // 가운데: 목록
        _search.PlaceholderText = Strings.S("search");
        _search.TextChanged += (_, _) => ReloadList();
        _list.Columns.Add(Strings.S("col.abbreviation"), 130);
        _list.Columns.Add(Strings.S("col.label"), 170);
        _list.Columns.Add(Strings.S("col.group"), 90);
        _list.SelectedIndexChanged += (_, _) =>
        {
            if (_loading) return;
            if (_list.SelectedItems.Count == 1 && _list.SelectedItems[0].Tag is (SnippetGroup g, Snippet s)) SelectSnippet(g, s);
        };
        var listButtons = new FlowLayoutPanel { Dock = DockStyle.Bottom, AutoSize = true };
        listButtons.Controls.Add(Button("snippet.add", AddSnippet));
        listButtons.Controls.Add(Button("snippet.duplicate", DuplicateSnippet));
        listButtons.Controls.Add(Button("snippet.delete", DeleteSnippet));
        var middle = new Panel { Dock = DockStyle.Fill, Padding = new Padding(6) };
        middle.Controls.Add(_list);
        middle.Controls.Add(_search);
        middle.Controls.Add(listButtons);

        // 오른쪽: 편집기
        BuildEditor();
        var right = new Panel { Dock = DockStyle.Fill };
        right.Controls.Add(_editor);
        right.Controls.Add(_editorEmpty);
        _editorEmpty.Text = Strings.S("editor.empty");

        // 분할 위치는 창이 제 크기를 가진 뒤(Load)에 정한다 — 기본 폭에서 정하면 잘려 버린다.
        var inner = new SplitContainer { Dock = DockStyle.Fill, FixedPanel = FixedPanel.Panel1 };
        inner.Panel1.Controls.Add(middle);
        inner.Panel2.Controls.Add(right);
        var outer = new SplitContainer { Dock = DockStyle.Fill, FixedPanel = FixedPanel.Panel1 };
        Load += (_, _) => { outer.SplitterDistance = 200; inner.SplitterDistance = 330; };
        outer.Panel1.Controls.Add(left);
        outer.Panel2.Controls.Add(inner);
        page.Controls.Add(outer);
        return page;
    }

    private void BuildEditor()
    {
        _enabled.Text = Strings.S("editor.enabled");
        _caseSensitive.Text = Strings.S("editor.caseSensitive");
        _adaptCase.Text = Strings.S("editor.adaptCase");
        new ToolTip().SetToolTip(_adaptCase, Strings.S("editor.adaptCase.help"));

        var macroButton = new Button { Text = Strings.S("editor.insertMacro") + " ▾", AutoSize = true };
        var macroMenu = new ContextMenuStrip();
        void AddMacro(string key, string macro) => macroMenu.Items.Add(Strings.S(key), null, (_, _) => InsertAtCursor(macro));
        AddMacro("macro.fillText", "%filltext:name=field%");
        AddMacro("macro.fillArea", "%fillarea:name=notes%");
        AddMacro("macro.fillPopup", "%fillpopup:name=choice:one:two:default=one%");
        AddMacro("macro.fillPart", "%fillpart:name=optional:default=yes%…%fillpartend%");
        macroMenu.Items.Add(new ToolStripSeparator());
        AddMacro("macro.clipboard", "%clipboard");
        AddMacro("macro.date", "%date:yyyy-MM-dd%");
        AddMacro("macro.tomorrow", "%date:+1d:yyyy-MM-dd%");
        AddMacro("macro.time", "%date:HH:mm%");
        AddMacro("macro.cursor", "%|");
        AddMacro("macro.enter", "%key:enter%");
        macroButton.Click += (_, _) => macroMenu.Show(macroButton, new Point(0, macroButton.Height));

        var options = new FlowLayoutPanel { Dock = DockStyle.Top, AutoSize = true };
        options.Controls.AddRange(new Control[] { _enabled, _caseSensitive, _adaptCase, macroButton });

        var contentLabel = new Label { Text = Strings.S("editor.content"), Dock = DockStyle.Top, AutoSize = true, Padding = new Padding(0, 6, 0, 0) };
        var previewLabel = new Label { Text = Strings.S("editor.preview"), Dock = DockStyle.Bottom, AutoSize = true, Padding = new Padding(0, 6, 0, 0) };

        // Dock 은 뒤에 넣은 것이 먼저 자리를 잡는다 — 위에서 아래 순서의 역순으로 넣는다.
        _editor.Controls.Add(_content);
        _editor.Controls.Add(contentLabel);
        _editor.Controls.Add(_conflict);
        _editor.Controls.Add(options);
        _editor.Controls.Add(_label);
        _editor.Controls.Add(new Label { Text = Strings.S("editor.label"), Dock = DockStyle.Top, AutoSize = true, Padding = new Padding(0, 6, 0, 0) });
        _editor.Controls.Add(_abbreviation);
        _editor.Controls.Add(new Label { Text = Strings.S("editor.abbreviation"), Dock = DockStyle.Top, AutoSize = true });
        _editor.Controls.Add(previewLabel);
        _editor.Controls.Add(_preview);
        previewLabel.BringToFront();
        _preview.SendToBack();

        _abbreviation.Font = new Font(FontFamily.GenericMonospace, 10f);
        _content.Font = new Font(FontFamily.GenericMonospace, 10f);

        _abbreviation.TextChanged += (_, _) => Edit(s => s.Abbreviation = _abbreviation.Text);
        _label.TextChanged += (_, _) => Edit(s => s.Label = _label.Text);
        _content.TextChanged += (_, _) => Edit(s => s.Content = _content.Text);
        _enabled.CheckedChanged += (_, _) => Edit(s => s.Enabled = _enabled.Checked);
        _caseSensitive.CheckedChanged += (_, _) => Edit(s => s.CaseSensitive = _caseSensitive.Checked);
        _adaptCase.CheckedChanged += (_, _) =>
        {
            _caseSensitive.Enabled = !_adaptCase.Checked; // 따라가기는 대소문자 구분을 끈 것과 같다
            Edit(s => s.AdaptCase = _adaptCase.Checked);
        };
    }

    private Button Button(string key, Action action)
    {
        var b = new Button { Text = Strings.S(key), AutoSize = true };
        b.Click += (_, _) => action();
        return b;
    }

    private void ReloadGroups(Guid? selectGroup = null, Guid? selectSnippet = null)
    {
        _loading = true;
        _groups.DataSource = null;
        _groups.DataSource = Library.Data.Groups;
        _loading = false;
        var group = Library.Data.Groups.FirstOrDefault(g => g.Id == selectGroup) ?? Library.Data.Groups.FirstOrDefault();
        if (group is not null) _groups.SelectedItem = group;
        SelectGroup(group, selectSnippet);
    }

    private void SelectGroup(SnippetGroup? group, Guid? selectSnippet = null)
    {
        _group = group;
        _loading = true;
        _groupEnabled.Checked = group?.Enabled ?? false;
        _groupEnabled.Enabled = group is not null;
        _loading = false;
        ReloadList();
        var snippet = group?.Snippets.FirstOrDefault(s => s.Id == selectSnippet) ?? group?.Snippets.FirstOrDefault();
        if (group is not null && snippet is not null) SelectSnippet(group, snippet);
        else ShowEditor(null);
    }

    private void ReloadList()
    {
        _loading = true;
        _list.BeginUpdate();
        _list.Items.Clear();
        var query = _search.Text.Trim();
        var rows = query.Length > 0
            ? SnippetSearch.Run(query, Library.Data.Groups).Select(h => (Library.Data.Groups.First(g => g.Id == h.GroupId), h.Snippet))
            : (_group?.Snippets.Select(s => (_group, s)) ?? Enumerable.Empty<(SnippetGroup, Snippet)>());
        foreach (var (g, s) in rows)
        {
            var item = new ListViewItem(new[] { s.Abbreviation, s.DisplayTitle, g.Name }) { Tag = (g, s) };
            if (!s.Enabled || !g.Enabled) item.ForeColor = SystemColors.GrayText;
            if (s == _snippet) item.Selected = true;
            _list.Items.Add(item);
        }
        _list.EndUpdate();
        _loading = false;
    }

    private void SelectSnippet(SnippetGroup group, Snippet snippet)
    {
        FlushPendingSave();
        _group = group;
        _snippet = snippet;
        ShowEditor(snippet);
    }

    private void ShowEditor(Snippet? s)
    {
        _editor.Visible = s is not null;
        _editorEmpty.Visible = s is null;
        if (s is null) { _snippet = null; return; }
        _loading = true;
        _abbreviation.Text = s.Abbreviation;
        _label.Text = s.Label;
        _content.Text = s.Content;
        _enabled.Checked = s.Enabled;
        _caseSensitive.Checked = s.CaseSensitive;
        _adaptCase.Checked = s.AdaptCase;
        _caseSensitive.Enabled = !s.AdaptCase;
        _loading = false;
        UpdateDerived();
    }

    private void Edit(Action<Snippet> change)
    {
        if (_loading || _snippet is null || Library.IsReadOnly) return;
        change(_snippet);
        _snippet.ModifiedAt = Iso8601.Now();
        ScheduleSave();
        UpdateDerived();
        // 목록의 현재 줄만 고친다(전체를 다시 그리면 포커스가 튄다).
        foreach (ListViewItem item in _list.Items)
        {
            if (item.Tag is not (SnippetGroup _, Snippet s) || s != _snippet) continue;
            item.SubItems[0].Text = s.Abbreviation;
            item.SubItems[1].Text = s.DisplayTitle;
            item.ForeColor = s.Enabled ? SystemColors.WindowText : SystemColors.GrayText;
        }
    }

    private void UpdateDerived()
    {
        if (_snippet is null) return;
        var s = _snippet;
        var key = Matcher.MatchesCaseInsensitively(s) ? s.Abbreviation.ToLowerInvariant() : s.Abbreviation;
        var clash = s.Enabled && s.Abbreviation.Length > 0 && Library.Data.Groups
            .Where(g => g.Enabled).SelectMany(g => g.Snippets)
            .Count(o => o.Enabled && (Matcher.MatchesCaseInsensitively(o) ? o.Abbreviation.ToLowerInvariant() : o.Abbreviation) == key) > 1;
        _conflict.Text = clash ? Strings.S("editor.conflict", s.Abbreviation) : "";
        try
        {
            var tokens = MacroParser.Parse(MacroParser.ResolveNested(s.Content, a => Library.SnippetFor(a)?.Content));
            _preview.Text = MacroParser.Render(tokens, clipboard: () => "[clipboard]").Text;
        }
        catch (FormatException) { _preview.Text = ""; }
    }

    private void InsertAtCursor(string macro)
    {
        if (_snippet is null) return;
        var at = _content.SelectionStart;
        _content.Text = _content.Text.Insert(at, macro);
        _content.SelectionStart = at + macro.Length;
        _content.Focus();
    }

    private void AddGroup()
    {
        var g = new SnippetGroup { Name = Strings.S("group.new") };
        Library.Data.Groups.Add(g);
        _app.Save();
        ReloadGroups(g.Id);
    }

    private void RenameGroup()
    {
        if (_group is null) return;
        var name = Prompt.Ask(Strings.S("group.rename"), _group.Name);
        if (string.IsNullOrWhiteSpace(name)) return;
        _group.Name = name.Trim();
        _app.Save();
        ReloadGroups(_group.Id);
    }

    private void DeleteGroup()
    {
        if (_group is null) return;
        if (MessageBox.Show(this, Strings.S("group.deleteConfirm", _group.Name, _group.Snippets.Count), "SnipKey",
                MessageBoxButtons.OKCancel, MessageBoxIcon.Warning) != DialogResult.OK) return;
        Library.Data.Groups.Remove(_group);
        _app.Save();
        ReloadGroups();
    }

    private void AddSnippet()
    {
        if (_group is null)
        {
            AddGroup();
            if (_group is null) return;
        }
        var s = new Snippet();
        _group.Snippets.Add(s);
        _app.Save();
        ReloadGroups(_group.Id, s.Id);
        _abbreviation.Focus();
    }

    private void DuplicateSnippet()
    {
        if (_group is null || _snippet is null) return;
        var copy = _snippet.Clone();
        copy.Id = Guid.NewGuid();
        copy.Abbreviation = AbbreviationNaming.Duplicate(_snippet.Abbreviation, Library.AllSnippets.Select(x => x.Abbreviation).ToHashSet());
        copy.Label = _snippet.Label.Length == 0 ? "" : _snippet.Label + " copy";
        copy.CreatedAt = copy.ModifiedAt = Iso8601.Now();
        _group.Snippets.Add(copy);
        _app.Save();
        ReloadGroups(_group.Id, copy.Id);
    }

    private void DeleteSnippet()
    {
        if (_group is null || _snippet is null) return;
        if (MessageBox.Show(this, Strings.S("snippet.deleteConfirm", _snippet.DisplayTitle), "SnipKey",
                MessageBoxButtons.OKCancel, MessageBoxIcon.Warning) != DialogResult.OK) return;
        _saveTimer.Stop();
        _group.Snippets.Remove(_snippet);
        _snippet = null;
        _app.Save();
        ReloadGroups(_group.Id);
    }
}

/// <summary>한 줄 입력 대화상자.</summary>
internal static class Prompt
{
    public static string? Ask(string title, string initial)
    {
        using var form = new Form
        {
            Text = title, FormBorderStyle = FormBorderStyle.FixedDialog, StartPosition = FormStartPosition.CenterParent,
            MinimizeBox = false, MaximizeBox = false, ClientSize = new Size(360, 90), ShowInTaskbar = false,
        };
        var box = new TextBox { Text = initial, Left = 12, Top = 14, Width = 336 };
        var ok = new Button { Text = "OK", DialogResult = DialogResult.OK, Left = 192, Top = 50, Width = 75 };
        var cancel = new Button { Text = Strings.S("fill.cancel"), DialogResult = DialogResult.Cancel, Left = 273, Top = 50, Width = 75 };
        form.Controls.AddRange(new Control[] { box, ok, cancel });
        form.AcceptButton = ok;
        form.CancelButton = cancel;
        return form.ShowDialog() == DialogResult.OK ? box.Text : null;
    }
}

/// <summary>설정 탭.</summary>
internal sealed class SettingsPage : TabPage
{
    private static readonly (string Label, int Mods, int Key)[] HotkeyPresets =
    {
        ("Ctrl+Shift+Space", 0x0002 | 0x0004, 0x20),
        ("Ctrl+Alt+Space", 0x0002 | 0x0001, 0x20),
        ("Ctrl+Shift+K", 0x0002 | 0x0004, 0x4B),
        ("Ctrl+Shift+Y", 0x0002 | 0x0004, 0x59),
    };

    private readonly App _app;
    private readonly ListBox _excluded = new() { Height = 90, Width = 360, IntegralHeight = false };
    private readonly Label _libraryPath = new() { AutoSize = true, MaximumSize = new Size(700, 0) };

    public SettingsPage(App app)
    {
        _app = app;
        AutoScroll = true;
        var s = app.Settings;
        var flow = new FlowLayoutPanel { Dock = DockStyle.Fill, FlowDirection = FlowDirection.TopDown, WrapContents = false, AutoScroll = true, Padding = new Padding(12) };

        flow.Controls.Add(Check("settings.expansion", s.ExpansionEnabled, v => s.ExpansionEnabled = v));
        flow.Controls.Add(Check("settings.sound", s.PlaySound, v => s.PlaySound = v));
        flow.Controls.Add(Check("settings.undo", s.UndoWithBackspace, v => s.UndoWithBackspace = v));
        flow.Controls.Add(Check("settings.login", LoginItem.IsEnabled, LoginItem.Set));

        flow.Controls.Add(Header("settings.search"));
        var hotkey = new ComboBox { DropDownStyle = ComboBoxStyle.DropDownList, Width = 200 };
        hotkey.Items.AddRange(HotkeyPresets.Select(p => (object)p.Label).ToArray());
        hotkey.SelectedIndex = Math.Max(0, Array.FindIndex(HotkeyPresets, p => p.Mods == s.SearchHotkeyModifiers && p.Key == s.SearchHotkeyKey));
        hotkey.SelectedIndexChanged += (_, _) =>
        {
            var p = HotkeyPresets[hotkey.SelectedIndex];
            s.SearchHotkeyModifiers = p.Mods;
            s.SearchHotkeyKey = p.Key;
            app.SettingsChanged();
        };
        flow.Controls.Add(hotkey);

        flow.Controls.Add(Header("settings.language"));
        var language = new ComboBox { DropDownStyle = ComboBoxStyle.DropDownList, Width = 200 };
        var codes = new[] { "system", "en", "ko", "ja" };
        language.Items.AddRange(new object[] { Strings.S("settings.language.system"), "English", "한국어", "日本語" });
        language.SelectedIndex = Math.Max(0, Array.IndexOf(codes, s.Language));
        language.SelectedIndexChanged += (_, _) => { s.Language = codes[language.SelectedIndex]; app.SettingsChanged(); };
        flow.Controls.Add(language);

        flow.Controls.Add(Header("settings.excluded"));
        _excluded.Items.AddRange(s.ExcludedApps.Cast<object>().ToArray());
        flow.Controls.Add(_excluded);
        var exButtons = new FlowLayoutPanel { AutoSize = true };
        exButtons.Controls.Add(Btn("settings.excluded.add", AddExcluded));
        exButtons.Controls.Add(Btn("settings.excluded.remove", () =>
        {
            if (_excluded.SelectedItem is not string exe) return;
            s.ExcludedApps.Remove(exe);
            _excluded.Items.Remove(exe);
            app.SettingsChanged();
        }));
        flow.Controls.Add(exButtons);

        flow.Controls.Add(Header("settings.library"));
        flow.Controls.Add(_libraryPath);
        var libButtons = new FlowLayoutPanel { AutoSize = true };
        libButtons.Controls.Add(Btn("settings.library.saveAs", SaveAs));
        libButtons.Controls.Add(Btn("settings.library.link", Link));
        libButtons.Controls.Add(Btn("settings.library.local", () => { app.UseLocalLibrary(); UpdatePath(); }));
        libButtons.Controls.Add(Btn("settings.import", Import));
        libButtons.Controls.Add(Btn("settings.openFolder", () =>
            Process.Start(new ProcessStartInfo("explorer.exe", $"\"{Path.GetDirectoryName(app.Library.File.FilePath)}\"") { UseShellExecute = true })));
        flow.Controls.Add(libButtons);
        flow.Controls.Add(new Label { Text = Strings.S("settings.library.hint"), AutoSize = true, MaximumSize = new Size(700, 0), ForeColor = SystemColors.GrayText });

        Controls.Add(flow);
        UpdatePath();
    }

    private void UpdatePath() => _libraryPath.Text = _app.Library.File.FilePath;

    private CheckBox Check(string key, bool value, Action<bool> set)
    {
        var c = new CheckBox { Text = Strings.S(key), Checked = value, AutoSize = true };
        c.CheckedChanged += (_, _) => { set(c.Checked); _app.SettingsChanged(); };
        return c;
    }

    private static Label Header(string key) => new()
    {
        Text = Strings.S(key), AutoSize = true, Font = new Font(SystemFonts.MessageBoxFont ?? SystemFonts.DefaultFont, FontStyle.Bold),
        Padding = new Padding(0, 12, 0, 2),
    };

    private static Button Btn(string key, Action action)
    {
        var b = new Button { Text = Strings.S(key), AutoSize = true };
        b.Click += (_, _) => action();
        return b;
    }

    private void AddExcluded()
    {
        using var dialog = new OpenFileDialog { Filter = "Programs (*.exe)|*.exe", Multiselect = true };
        if (dialog.ShowDialog(this) != DialogResult.OK) return;
        foreach (var file in dialog.FileNames)
        {
            var exe = Path.GetFileName(file).ToLowerInvariant();
            if (_app.Settings.ExcludedApps.Contains(exe)) continue;
            _app.Settings.ExcludedApps.Add(exe);
            _excluded.Items.Add(exe);
        }
        _app.SettingsChanged();
    }

    private void SaveAs()
    {
        using var dialog = new FolderBrowserDialog();
        if (dialog.ShowDialog(this) != DialogResult.OK) return;
        if (_app.SaveLibraryAs(dialog.SelectedPath, out var error)) UpdatePath();
        else MessageBox.Show(this, Strings.S("settings.library.linkFailed", error ?? "?"), "SnipKey");
    }

    private void Link()
    {
        using var dialog = new OpenFileDialog { Filter = "SnipKey library (*.json)|*.json" };
        if (dialog.ShowDialog(this) != DialogResult.OK) return;
        if (_app.LinkLibrary(dialog.FileName, out var error)) UpdatePath();
        else MessageBox.Show(this, Strings.S("settings.library.linkFailed", error ?? "?"), "SnipKey");
    }

    private void Import()
    {
        using var dialog = new OpenFileDialog { Filter = "SnipKey JSON (*.json)|*.json" };
        if (dialog.ShowDialog(this) != DialogResult.OK) return;
        try
        {
            var imported = StoreJson.Deserialize(File.ReadAllBytes(dialog.FileName));
            var count = _app.Import(imported.Groups);
            MessageBox.Show(this, Strings.S("settings.import.done", count, imported.Groups.Count), "SnipKey");
        }
        catch (Exception e) when (e is IOException or System.Text.Json.JsonException)
        {
            MessageBox.Show(this, Strings.S("settings.library.linkFailed", e.Message), "SnipKey");
        }
    }
}
