import SwiftUI
import AppKit
import SnipKeyKit

struct ManagerView: View {
    @EnvironmentObject var store: Store
    @EnvironmentObject var loc: LocalizationManager

    /// 어느 탭을 보여줄지. ⌘,가 Settings 탭을 직접 고를 수 있으려면 선택 바인딩이
    /// 있어야 한다(예전엔 바인딩이 없어 프로그램적으로 탭을 바꿀 수 없었다).
    enum Tab: Hashable {
        case snippets
        case settings
    }

    @State private var selectedTab: Tab = .snippets

    var body: some View {
        // Hotkeys(단축키 매크로) 탭은 이 버전에서 감춘다 — 아직 미완성이고 테스트가 없다.
        // HotkeysTab/HotkeyManager 코드는 나중에 다시 켤 수 있게 그대로 둔다(⌘/ 인라인
        // 검색은 HotkeyManager가 계속 등록한다). 여기서 참조만 뗀다.
        TabView(selection: $selectedTab) {
            SnippetsTab()
                .tabItem { Label(loc.s("tab.snippets"), systemImage: "text.badge.plus") }
                .tag(Tab.snippets)
            SettingsTab()
                .tabItem { Label(loc.s("tab.settings"), systemImage: "gearshape") }
                .tag(Tab.settings)
        }
        .frame(minWidth: 900, minHeight: 560)
        // ⌘,는 창을 띄운 뒤 이 알림을 쏜다. 창이 이미 떠 있든 아니든 Settings 탭으로 간다.
        .onReceive(NotificationCenter.default.publisher(for: .snipKeyOpenSettings)) { _ in
            selectedTab = .settings
        }
    }
}

// MARK: - Snippets

/// How the snippet list is ordered. Mirrors the sort options TextExpander
/// offers, and is remembered for the session.
enum SnippetSort: String, CaseIterable, Identifiable {
    case abbreviation
    case label
    case recentlyModified

    var id: String { rawValue }

    /// 현지화 카탈로그 키. 열거형은 View가 아니라 @EnvironmentObject를 쓸 수 없으므로,
    /// 표시할 때 호출부에서 loc.s(locKey)로 번역한다.
    var locKey: String {
        switch self {
        case .abbreviation: return "sort.abbreviation"
        case .label: return "sort.label"
        case .recentlyModified: return "sort.recentlyModified"
        }
    }
}

struct SnippetsTab: View {
    @EnvironmentObject var store: Store
    @EnvironmentObject var loc: LocalizationManager

    @State private var selectedGroupID: UUID?
    @State private var selectedSnippetID: UUID?
    @State private var searchText = ""
    @State private var sort: SnippetSort = .abbreviation
    /// Set briefly after a snippet is created so the row can flash.
    @State private var justAddedID: UUID?
    @FocusState private var searchFocused: Bool

    private var isSearching: Bool {
        !searchText.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private var selectedGroup: SnippetGroup? {
        store.groups.first { $0.id == selectedGroupID }
    }

    /// Search spans every group; otherwise show the selected group, sorted.
    private var visibleHits: [SearchHit] {
        if isSearching {
            return store.search(searchText)
        }
        guard let group = selectedGroup else { return [] }
        let hits = group.snippets.map {
            SearchHit(snippet: $0, groupID: group.id, groupName: group.name, score: 0)
        }
        return sorted(hits)
    }

    private func sorted(_ hits: [SearchHit]) -> [SearchHit] {
        switch sort {
        case .abbreviation:
            return hits.sorted {
                $0.snippet.abbreviation.localizedCaseInsensitiveCompare($1.snippet.abbreviation) == .orderedAscending
            }
        case .label:
            return hits.sorted {
                $0.snippet.displayTitle.localizedCaseInsensitiveCompare($1.snippet.displayTitle) == .orderedAscending
            }
        case .recentlyModified:
            return hits.sorted { $0.snippet.modifiedAt > $1.snippet.modifiedAt }
        }
    }

    var body: some View {
        HSplitView {
            groupsSidebar
                .frame(minWidth: 180, idealWidth: 210, maxWidth: 300)
            snippetList
                .frame(minWidth: 260, idealWidth: 300, maxWidth: 420)
            editorPane
                .frame(minWidth: 380, maxWidth: .infinity)
        }
        .onAppear {
            if selectedGroupID == nil { selectedGroupID = store.groups.first?.id }
        }
        // ⌘N and ⌘F come from the real main menu (see MainMenu.swift). SwiftUI's
        // .keyboardShortcut is not dependable in an app that starts life without
        // a menu bar.
        .onReceive(NotificationCenter.default.publisher(for: .snipKeyNewSnippet)) { _ in
            addSnippet()
        }
        .onReceive(NotificationCenter.default.publisher(for: .snipKeyFocusSearch)) { _ in
            searchFocused = true
        }
    }

    // MARK: Groups

    private var groupsSidebar: some View {
        VStack(spacing: 0) {
            List(selection: $selectedGroupID) {
                Section(loc.s("snippets.groups.header")) {
                    ForEach(store.groups) { group in
                        HStack {
                            Text(group.name)
                                .foregroundStyle(group.enabled ? .primary : .secondary)
                            Spacer()
                            if !group.enabled {
                                Image(systemName: "pause.circle")
                                    .foregroundStyle(.orange)
                                    .help(loc.s("snippets.group.disabled.help"))
                            }
                            Text("\(group.snippets.count)")
                                .foregroundStyle(.secondary)
                                .font(.caption)
                        }
                        .tag(group.id)
                        .contextMenu {
                            Button(group.enabled ? loc.s("snippets.group.disable") : loc.s("snippets.group.enable")) {
                                toggleGroup(group.id)
                            }
                            Button(loc.s("snippets.group.rename")) { renameGroup(group.id) }
                            Divider()
                            Button(loc.s("snippets.group.delete"), role: .destructive) { deleteGroup(group) }
                        }
                    }
                }
            }
            .listStyle(.sidebar)

            HStack(spacing: 2) {
                Button {
                    let group = store.addGroup(named: loc.s("snippets.group.newDefaultName"))
                    selectedGroupID = group.id
                    searchText = ""
                } label: {
                    Image(systemName: "plus")
                }
                .buttonStyle(.borderless)
                .help(loc.s("snippets.newGroup.help"))
                Spacer()
                Text(loc.s("snippets.count", store.allSnippets.count))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .padding(8)
        }
    }

    // MARK: Snippet list

    private var snippetList: some View {
        VStack(spacing: 0) {
            searchBar

            if visibleHits.isEmpty {
                emptyList
            } else {
                ScrollViewReader { proxy in
                    List(selection: $selectedSnippetID) {
                        ForEach(visibleHits) { hit in
                            SnippetRow(
                                hit: hit,
                                showGroup: isSearching,
                                isConflicting: conflicts.contains(conflictKey(hit.snippet)),
                                justAdded: hit.snippet.id == justAddedID
                            )
                            .tag(hit.snippet.id)
                            .id(hit.snippet.id)
                            .contextMenu {
                                Button(loc.s("snippets.duplicate")) { duplicate(hit) }
                                Button(hit.snippet.enabled ? loc.s("snippets.disable") : loc.s("snippets.enable")) { toggleSnippet(hit) }
                                Divider()
                                Button(loc.s("common.delete"), role: .destructive) {
                                    store.removeSnippet(id: hit.snippet.id, fromGroup: hit.groupID)
                                    if selectedSnippetID == hit.snippet.id { selectedSnippetID = nil }
                                }
                            }
                        }
                    }
                    .onChange(of: justAddedID) { id in
                        // Bring the brand-new snippet into view so it is obvious
                        // that something was added.
                        guard let id else { return }
                        withAnimation(.easeOut(duration: 0.25)) {
                            proxy.scrollTo(id, anchor: .center)
                        }
                    }
                }
            }

            listFooter
        }
    }

    private var searchBar: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .font(.callout)
            TextField(loc.s("snippets.search.placeholder"), text: $searchText)
                .textFieldStyle(.plain)
                .focused($searchFocused)
            if !searchText.isEmpty {
                Button {
                    searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help(loc.s("snippets.clearSearch"))
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
        .padding(8)
    }

    private var emptyList: some View {
        VStack(spacing: 8) {
            Image(systemName: isSearching ? "magnifyingglass" : "tray")
                .font(.largeTitle)
                .foregroundStyle(.tertiary)
            if isSearching {
                Text(loc.s("snippets.empty.noMatch", searchText))
                    .foregroundStyle(.secondary)
                Button(loc.s("snippets.clearSearch")) { searchText = "" }
                    .buttonStyle(.link)
            } else {
                Text(loc.s("snippets.empty.groupEmpty"))
                    .foregroundStyle(.secondary)
                Button(loc.s("snippets.empty.addOne")) { addSnippet() }
                    .buttonStyle(.link)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var listFooter: some View {
        HStack(spacing: 2) {
            Button { addSnippet() } label: { Image(systemName: "plus") }
                .buttonStyle(.borderless)
                .disabled(store.groups.isEmpty)
                .help(loc.s("snippets.new.help"))

            Button { deleteSelectedSnippet() } label: { Image(systemName: "minus") }
                .buttonStyle(.borderless)
                .disabled(selectedSnippetID == nil)
                .help(loc.s("snippets.delete.help"))

            Spacer()

            if isSearching {
                Text(loc.s("snippets.found", visibleHits.count))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Picker("", selection: $sort) {
                    ForEach(SnippetSort.allCases) { option in
                        Text(loc.s(option.locKey)).tag(option)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .fixedSize()
                .help(loc.s("snippets.sort.help"))
            }
        }
        .padding(8)
    }

    // MARK: Editor

    @ViewBuilder
    private var editorPane: some View {
        if let snippetID = selectedSnippetID,
           let (groupID, snippet) = locate(snippetID: snippetID) {
            SnippetEditor(
                snippet: snippet,
                conflicts: store.snippetsClaiming(abbreviation: snippet.abbreviation, excluding: snippet.id),
                focusAbbreviationOnAppear: snippet.id == justAddedID,
                onChange: { updated in
                    var copy = updated
                    copy.modifiedAt = Date()
                    store.updateSnippet(copy, inGroup: groupID)
                }
            )
            .id(snippetID)
        } else {
            VStack(spacing: 10) {
                Image(systemName: "text.badge.plus")
                    .font(.system(size: 40))
                    .foregroundStyle(.tertiary)
                Text(loc.s("editor.empty.title"))
                    .foregroundStyle(.secondary)
                Text(loc.s("editor.empty.hint"))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: Helpers

    private var conflicts: Set<String> { store.conflictingAbbreviations() }

    private func conflictKey(_ snippet: Snippet) -> String {
        snippet.caseSensitive ? snippet.abbreviation : snippet.abbreviation.lowercased()
    }

    private func locate(snippetID: UUID) -> (UUID, Snippet)? {
        for group in store.groups {
            if let s = group.snippets.first(where: { $0.id == snippetID }) {
                return (group.id, s)
            }
        }
        return nil
    }

    private func addSnippet() {
        // A new snippet belongs in a visible group, so leave the search first.
        searchText = ""
        guard let groupID = selectedGroupID ?? store.groups.first?.id else { return }
        selectedGroupID = groupID

        // Sort by recency for a moment so the new (empty) snippet is not sorted
        // into the middle of the list where the user cannot see it appear.
        sort = .recentlyModified

        let snippet = Snippet(abbreviation: "", content: "")
        store.updateSnippet(snippet, inGroup: groupID)
        selectedSnippetID = snippet.id

        withAnimation(.easeOut(duration: 0.25)) {
            justAddedID = snippet.id
        }
        // Let the highlight fade after it has been noticed.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
            withAnimation(.easeInOut(duration: 0.6)) {
                if justAddedID == snippet.id { justAddedID = nil }
            }
        }
    }

    private func duplicate(_ hit: SearchHit) {
        var copy = hit.snippet
        copy.id = UUID()
        copy.abbreviation = hit.snippet.abbreviation + "2"
        copy.label = hit.snippet.label.isEmpty ? "" : hit.snippet.label + " copy"
        copy.createdAt = Date()
        copy.modifiedAt = Date()
        store.updateSnippet(copy, inGroup: hit.groupID)
        selectedGroupID = hit.groupID
        selectedSnippetID = copy.id
        withAnimation { justAddedID = copy.id }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
            withAnimation { if justAddedID == copy.id { justAddedID = nil } }
        }
    }

    private func toggleSnippet(_ hit: SearchHit) {
        var copy = hit.snippet
        copy.enabled.toggle()
        store.updateSnippet(copy, inGroup: hit.groupID)
    }

    private func deleteSelectedSnippet() {
        guard let id = selectedSnippetID, let (groupID, _) = locate(snippetID: id) else { return }
        store.removeSnippet(id: id, fromGroup: groupID)
        selectedSnippetID = nil
    }

    private func toggleGroup(_ id: UUID) {
        guard let idx = store.groupIndex(of: id) else { return }
        store.groups[idx].enabled.toggle()
    }

    private func renameGroup(_ id: UUID) {
        guard let idx = store.groupIndex(of: id) else { return }
        let alert = NSAlert()
        alert.messageText = loc.s("snippets.group.renameTitle")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.stringValue = store.groups[idx].name
        alert.accessoryView = field
        alert.addButton(withTitle: loc.s("common.rename"))
        alert.addButton(withTitle: loc.s("common.cancel"))
        if alert.runModal() == .alertFirstButtonReturn, !field.stringValue.isEmpty {
            store.groups[idx].name = field.stringValue
        }
    }

    private func deleteGroup(_ group: SnippetGroup) {
        guard !group.snippets.isEmpty else {
            store.removeGroup(id: group.id)
            if selectedGroupID == group.id { selectedGroupID = store.groups.first?.id }
            return
        }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = loc.s("snippets.group.deleteTitle", group.name)
        alert.informativeText = loc.s("snippets.group.deleteMessage", group.snippets.count)
        alert.addButton(withTitle: loc.s("common.delete"))
        alert.addButton(withTitle: loc.s("common.cancel"))
        if alert.runModal() == .alertFirstButtonReturn {
            store.removeGroup(id: group.id)
            if selectedGroupID == group.id { selectedGroupID = store.groups.first?.id }
        }
    }
}

// MARK: - Row

private struct SnippetRow: View {
    @EnvironmentObject var loc: LocalizationManager
    let hit: SearchHit
    let showGroup: Bool
    let isConflicting: Bool
    let justAdded: Bool

    private var snippet: Snippet { hit.snippet }

    private var subtitle: String {
        if !snippet.label.isEmpty { return snippet.label }
        let preview = snippet.content
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespaces)
        return preview.isEmpty ? loc.s("snippets.row.empty") : preview
    }

    var body: some View {
        HStack(spacing: 6) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    if snippet.abbreviation.isEmpty {
                        Text(loc.s("snippets.row.noAbbreviation"))
                            .font(.system(.body, design: .monospaced))
                            .foregroundStyle(.tertiary)
                    } else {
                        Text(snippet.abbreviation)
                            .font(.system(.body, design: .monospaced))
                            .bold()
                    }
                    if isConflicting {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.orange)
                            .help(loc.s("snippets.row.conflict.help"))
                    }
                    if !snippet.enabled {
                        Image(systemName: "pause.circle")
                            .font(.caption)
                            .foregroundStyle(.orange)
                            .help(loc.s("snippets.row.disabled.help"))
                    }
                }
                HStack(spacing: 4) {
                    Text(subtitle)
                        .lineLimit(1)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if showGroup {
                        Text(hit.groupName)
                            .font(.caption2)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(.quaternary, in: RoundedRectangle(cornerRadius: 3))
                            .foregroundStyle(.secondary)
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
        // A freshly added snippet pulses so the user sees where it landed.
        .listRowBackground(
            justAdded
                ? Color.accentColor.opacity(0.22)
                : Color.clear
        )
        .overlay(alignment: .leading) {
            if justAdded {
                Rectangle()
                    .fill(Color.accentColor)
                    .frame(width: 3)
                    .transition(.opacity)
            }
        }
    }
}

// MARK: - Editor

struct SnippetEditor: View {
    @EnvironmentObject var loc: LocalizationManager
    @State var snippet: Snippet
    let conflicts: [SearchHit]
    let focusAbbreviationOnAppear: Bool
    let onChange: (Snippet) -> Void

    @FocusState private var abbreviationFocused: Bool
    // 미리보기 패널은 기본으로 접혀 있다. 눈 아이콘으로 켜면 확장 결과의 모양을
    // (실제 확장을 트리거하지 않고) 내용 편집기 바로 아래에서 보여 준다.
    @State private var showPreview = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(loc.s("editor.abbreviation.label")).font(.caption).foregroundStyle(.secondary)
                    TextField(loc.s("editor.abbreviation.placeholder"), text: $snippet.abbreviation)
                        .font(.system(.body, design: .monospaced))
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 180)
                        .focused($abbreviationFocused)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text(loc.s("editor.label.label")).font(.caption).foregroundStyle(.secondary)
                    TextField(loc.s("editor.label.placeholder"), text: $snippet.label)
                        .textFieldStyle(.roundedBorder)
                }
            }

            if !conflicts.isEmpty {
                Label(
                    conflicts.count == 1
                        ? loc.s("editor.conflict.one", snippet.abbreviation, conflicts[0].groupName)
                        : loc.s("editor.conflict.many", snippet.abbreviation, conflicts.count),
                    systemImage: "exclamationmark.triangle.fill"
                )
                .font(.caption)
                .foregroundStyle(.orange)
            }

            HStack(spacing: 16) {
                Toggle(loc.s("editor.enabled"), isOn: $snippet.enabled)
                Toggle(loc.s("editor.caseSensitive"), isOn: $snippet.caseSensitive)
                    .help(loc.s("editor.caseSensitive.help"))
                Spacer()
                Menu(loc.s("editor.insertMacro")) {
                    // 라벨만 현지화한다 — 매크로 구문(%filltext…)은 기능이므로 절대 번역하지 않는다.
                    macroButton(loc.s("macro.fillText"), "%filltext:name=field%")
                    macroButton(loc.s("macro.fillArea"), "%fillarea:name=notes%")
                    macroButton(loc.s("macro.fillPopup"), "%fillpopup:name=choice:option A:option B:default=option A%")
                    macroButton(loc.s("macro.fillPart"), "%fillpart:name=section:default=yes%...%fillpartend%")
                    Divider()
                    macroButton(loc.s("macro.clipboard"), "%clipboard")
                    macroButton(loc.s("macro.cursor"), "%|")
                    macroButton(loc.s("macro.snippet"), "%snippet:;abbrev%")
                    Divider()
                    macroButton(loc.s("macro.date"), "%date:yyyy-MM-dd%")
                    macroButton(loc.s("macro.time"), "%date:HH:mm%")
                    macroButton(loc.s("macro.key"), "%key:enter%")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()

                Button {
                    showPreview.toggle()
                } label: {
                    Image(systemName: showPreview ? "eye.fill" : "eye")
                }
                .buttonStyle(.borderless)
                .help(loc.s("editor.preview.help"))
            }

            Text(loc.s("editor.content")).font(.caption).foregroundStyle(.secondary)
            TextEditor(text: $snippet.content)
                .font(.system(.body, design: .monospaced))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))

            if showPreview {
                // snippet.content를 직접 읽으므로 내용이 바뀌면 자동으로 다시 렌더링된다.
                // 읽기 전용·선택 가능·스크롤 가능하게 두어 실제 출력처럼 보이게 한다.
                Text(loc.s("editor.preview.label")).font(.caption).foregroundStyle(.secondary)
                ScrollView {
                    Text(MacroPreview.render(snippet.content))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                        .padding(6)
                }
                .frame(minHeight: 80, maxHeight: 120)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
            }

            HStack {
                Text(loc.s("editor.dates",
                           snippet.createdAt.formatted(date: .abbreviated, time: .omitted),
                           snippet.modifiedAt.formatted(date: .abbreviated, time: .omitted)))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                Spacer()
                Text(loc.s("editor.charCount", snippet.content.count))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(14)
        .onAppear {
            // A brand-new snippet needs an abbreviation before it can do
            // anything, so put the cursor there.
            if focusAbbreviationOnAppear {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                    abbreviationFocused = true
                }
            }
        }
        .onChange(of: snippet) { newValue in
            onChange(newValue)
        }
    }

    private func macroButton(_ title: String, _ text: String) -> some View {
        Button(title) {
            snippet.content += text
        }
    }
}
