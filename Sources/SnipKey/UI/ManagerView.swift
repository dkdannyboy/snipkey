import SwiftUI
import SnipKeyKit

struct ManagerView: View {
    @EnvironmentObject var store: Store

    var body: some View {
        TabView {
            SnippetsTab()
                .tabItem { Label("Snippets", systemImage: "text.badge.plus") }
            HotkeysTab()
                .tabItem { Label("Hotkeys", systemImage: "command.square") }
            SettingsTab()
                .tabItem { Label("Settings", systemImage: "gearshape") }
        }
        .frame(minWidth: 900, minHeight: 560)
    }
}

// MARK: - Snippets

struct SnippetsTab: View {
    @EnvironmentObject var store: Store
    @State private var selectedGroupID: UUID?
    @State private var selectedSnippetID: UUID?
    @State private var searchText = ""

    private var selectedGroup: SnippetGroup? {
        store.groups.first { $0.id == selectedGroupID }
    }

    private var visibleSnippets: [Snippet] {
        let base: [Snippet]
        if searchText.isEmpty {
            base = selectedGroup?.snippets ?? []
        } else {
            // Search across all groups.
            base = store.allSnippets.filter {
                $0.abbreviation.localizedCaseInsensitiveContains(searchText)
                    || $0.label.localizedCaseInsensitiveContains(searchText)
                    || $0.content.localizedCaseInsensitiveContains(searchText)
            }
        }
        return base
    }

    var body: some View {
        HSplitView {
            groupsSidebar
                .frame(minWidth: 180, idealWidth: 200, maxWidth: 280)
            snippetList
                .frame(minWidth: 240, idealWidth: 280, maxWidth: 400)
            editorPane
                .frame(minWidth: 380, maxWidth: .infinity)
        }
        .onAppear {
            if selectedGroupID == nil { selectedGroupID = store.groups.first?.id }
        }
    }

    private var groupsSidebar: some View {
        VStack(spacing: 0) {
            List(selection: $selectedGroupID) {
                ForEach(store.groups) { group in
                    HStack {
                        Text(group.name)
                        Spacer()
                        Text("\(group.snippets.count)")
                            .foregroundStyle(.secondary)
                            .font(.caption)
                        if !group.enabled {
                            Image(systemName: "pause.circle").foregroundStyle(.orange)
                        }
                    }
                    .tag(group.id)
                    .contextMenu {
                        Button(group.enabled ? "Disable Group" : "Enable Group") {
                            toggleGroup(group.id)
                        }
                        Button("Rename…") { renameGroup(group.id) }
                        Divider()
                        Button("Delete Group", role: .destructive) {
                            store.removeGroup(id: group.id)
                            if selectedGroupID == group.id { selectedGroupID = store.groups.first?.id }
                        }
                    }
                }
            }
            .listStyle(.sidebar)
            HStack {
                Button {
                    let g = store.addGroup(named: "New Group")
                    selectedGroupID = g.id
                } label: {
                    Image(systemName: "plus")
                }
                .buttonStyle(.borderless)
                .help("Add group")
                Spacer()
            }
            .padding(8)
        }
    }

    private var snippetList: some View {
        VStack(spacing: 0) {
            TextField("Search all snippets", text: $searchText)
                .textFieldStyle(.roundedBorder)
                .padding(8)
            List(selection: $selectedSnippetID) {
                ForEach(visibleSnippets) { snippet in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text(snippet.abbreviation)
                                .font(.system(.body, design: .monospaced))
                                .bold()
                            if !snippet.enabled {
                                Image(systemName: "pause.circle")
                                    .foregroundStyle(.orange)
                                    .font(.caption)
                            }
                        }
                        Text(snippet.label.isEmpty
                             ? snippet.content.replacingOccurrences(of: "\n", with: " ")
                             : snippet.label)
                            .lineLimit(1)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .tag(snippet.id)
                }
            }
            HStack {
                Button {
                    addSnippet()
                } label: {
                    Image(systemName: "plus")
                }
                .buttonStyle(.borderless)
                .disabled(selectedGroup == nil)
                .help("Add snippet")
                Button {
                    deleteSelectedSnippet()
                } label: {
                    Image(systemName: "minus")
                }
                .buttonStyle(.borderless)
                .disabled(selectedSnippetID == nil)
                .help("Delete snippet")
                Spacer()
            }
            .padding(8)
        }
    }

    @ViewBuilder
    private var editorPane: some View {
        if let snippetID = selectedSnippetID,
           let (groupID, snippet) = locate(snippetID: snippetID) {
            SnippetEditor(
                snippet: snippet,
                onChange: { updated in
                    var copy = updated
                    copy.modifiedAt = Date()
                    store.updateSnippet(copy, inGroup: groupID)
                }
            )
            .id(snippetID)
        } else {
            VStack(spacing: 8) {
                Image(systemName: "text.badge.plus")
                    .font(.system(size: 40))
                    .foregroundStyle(.tertiary)
                Text("Select a snippet, or press + to create one")
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
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
        guard let groupID = selectedGroupID ?? store.groups.first?.id else { return }
        let s = Snippet(abbreviation: "", content: "")
        store.updateSnippet(s, inGroup: groupID)
        selectedSnippetID = s.id
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
        alert.messageText = "Rename Group"
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.stringValue = store.groups[idx].name
        alert.accessoryView = field
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn, !field.stringValue.isEmpty {
            store.groups[idx].name = field.stringValue
        }
    }
}

// MARK: - Snippet editor

struct SnippetEditor: View {
    @State var snippet: Snippet
    let onChange: (Snippet) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Abbreviation").font(.caption).foregroundStyle(.secondary)
                    TextField("e.g. ;sig", text: $snippet.abbreviation)
                        .font(.system(.body, design: .monospaced))
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 180)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("Label (optional)").font(.caption).foregroundStyle(.secondary)
                    TextField("Description", text: $snippet.label)
                        .textFieldStyle(.roundedBorder)
                }
            }

            HStack(spacing: 16) {
                Toggle("Enabled", isOn: $snippet.enabled)
                Toggle("Case sensitive", isOn: $snippet.caseSensitive)
                Spacer()
                Menu("Insert Macro") {
                    macroButton("Fill-in field", "%filltext:name=field%")
                    macroButton("Multi-line fill-in", "%fillarea:name=notes%")
                    macroButton("Popup choices", "%fillpopup:name=choice:option A:option B:default=option A%")
                    macroButton("Optional section", "%fillpart:name=section:default=yes%...%fillpartend%")
                    Divider()
                    macroButton("Clipboard", "%clipboard")
                    macroButton("Cursor position", "%|")
                    macroButton("Another snippet", "%snippet:;abbrev%")
                    Divider()
                    macroButton("Date (2026-07-12)", "%date:yyyy-MM-dd%")
                    macroButton("Time (14:30)", "%date:HH:mm%")
                    macroButton("Press Enter", "%key:enter%")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }

            Text("Content").font(.caption).foregroundStyle(.secondary)
            TextEditor(text: $snippet.content)
                .font(.system(.body, design: .monospaced))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))

            HStack {
                Text("Created \(snippet.createdAt.formatted(date: .abbreviated, time: .omitted)) · Modified \(snippet.modifiedAt.formatted(date: .abbreviated, time: .omitted))")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                Spacer()
            }
        }
        .padding(14)
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
