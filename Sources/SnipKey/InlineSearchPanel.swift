import AppKit
import Carbon.HIToolbox
import SwiftUI
import SnipKeyKit

/// The Spotlight-style palette that opens over whatever app you are typing in
/// (⌘/ by default). Search your whole library by abbreviation, label, or
/// content, press Return, and the snippet expands where your cursor was.
///
/// This is the feature that makes a large library usable — nobody remembers
/// 300 abbreviations.
enum InlineSearchPanel {

    private final class KeyablePanel: NSPanel {
        override var canBecomeKey: Bool { true }
        override var canBecomeMain: Bool { true }
    }

    private final class CloseWatcher: NSObject, NSWindowDelegate {
        private let onClose: () -> Void
        init(onClose: @escaping () -> Void) { self.onClose = onClose }
        func windowWillClose(_ notification: Notification) { onClose() }
    }

    private static var panel: NSPanel?
    private static var closeWatcher: CloseWatcher?

    static var isOpen: Bool { panel?.isVisible == true }

    static func toggle(store: Store, loc: LocalizationManager, onPick: @escaping (Snippet, NSRunningApplication?) -> Void) {
        if isOpen {
            close()
        } else {
            open(store: store, loc: loc, onPick: onPick)
        }
    }

    static func close() {
        panel?.close()
    }

    private static func open(store: Store, loc: LocalizationManager, onPick: @escaping (Snippet, NSRunningApplication?) -> Void) {
        // Remember where the user was typing, so the snippet lands back there.
        let sourceApp = NSWorkspace.shared.frontmostApplication

        // Spotlight식 팔레트라 창 자체엔 크롬이 없어야 한다. .titled를 쓰면 제목을
        // 숨기고 타이틀바를 투명 처리해도 macOS가 빈 타이틀바 영역을 그려, 팔레트
        // 위에 얇은 막대가 남는다. .borderless는 타이틀바를 아예 만들지 않는다.
        // 포커스는 KeyablePanel이 canBecomeKey/Main을 강제하므로 입력에 지장 없다.
        let panel = KeyablePanel(
            contentRect: NSRect(x: 0, y: 0, width: 620, height: 420),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isMovableByWindowBackground = true
        panel.level = .floating
        panel.isReleasedWhenClosed = false
        panel.becomesKeyOnlyIfNeeded = false
        panel.hidesOnDeactivate = false
        panel.backgroundColor = .clear

        let dismiss: () -> Void = { close() }
        let pick: (Snippet) -> Void = { snippet in
            close()
            onPick(snippet, sourceApp)
        }

        let view = InlineSearchView(store: store, loc: loc, onPick: pick, onCancel: dismiss)
        panel.contentView = NSHostingView(rootView: view)

        positionNearTop(panel)

        let watcher = CloseWatcher {
            self.panel = nil
            sourceApp?.activate()
        }
        closeWatcher = watcher
        panel.delegate = watcher

        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        panel.orderFrontRegardless()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
            NSApp.activate(ignoringOtherApps: true)
            panel.makeKeyAndOrderFront(nil)
        }

        self.panel = panel
    }

    /// Spotlight-style placement: horizontally centred, a third of the way down
    /// the screen the mouse is on. Sitting it right on the caret would be nicer
    /// still, but no cross-app API reports the caret reliably, and a palette
    /// that lands in the wrong place is worse than one that lands predictably.
    private static func positionNearTop(_ panel: NSPanel) {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) }
            ?? NSScreen.main
        guard let frame = screen?.visibleFrame else {
            panel.center()
            return
        }
        let size = panel.frame.size
        let origin = NSPoint(
            x: frame.midX - size.width / 2,
            y: frame.maxY - frame.height / 3 - size.height / 2
        )
        panel.setFrameOrigin(origin)
    }
}

// MARK: - View

private struct InlineSearchView: View {
    @ObservedObject var store: Store
    /// 팔레트도 NSHostingView로 띄우므로 SwiftUI 환경 밖이다. 값으로 넘겨받는다.
    let loc: LocalizationManager
    let onPick: (Snippet) -> Void
    let onCancel: () -> Void

    @State private var query = ""
    @State private var selection = 0
    @State private var keyMonitor: Any?
    @FocusState private var searchFocused: Bool

    private let maxResults = 50

    private var hits: [SearchHit] {
        if query.trimmingCharacters(in: .whitespaces).isEmpty {
            // Empty query: offer something useful rather than a blank void.
            return store.groups
                .filter(\.enabled)
                .flatMap { group in
                    group.snippets
                        .filter { $0.enabled && !$0.abbreviation.isEmpty }
                        .map { SearchHit(snippet: $0, groupID: group.id, groupName: group.name, score: 0) }
                }
                .sorted { $0.snippet.modifiedAt > $1.snippet.modifiedAt }
                .prefix(maxResults)
                .map { $0 }
        }
        return store.search(query, limit: maxResults)
    }

    var body: some View {
        VStack(spacing: 0) {
            searchField
            Divider()
            if hits.isEmpty {
                emptyState
            } else {
                resultList
            }
            Divider()
            footer
        }
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(.quaternary))
        .frame(width: 620, height: 420)
        .onAppear {
            searchFocused = true
            installKeyMonitor()
        }
        .onDisappear { removeKeyMonitor() }
        .onChange(of: query) { _ in selection = 0 }
        .background(quickPickShortcuts)
    }

    /// Arrow keys move the selection and Escape closes, while the text field
    /// keeps focus so the user never stops typing. (SwiftUI's `onKeyPress`
    /// would do this, but it needs macOS 14 and SnipKey supports 13.)
    private func installKeyMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            switch Int(event.keyCode) {
            case kVK_UpArrow:
                move(-1)
                return nil
            case kVK_DownArrow:
                move(1)
                return nil
            case kVK_Escape:
                onCancel()
                return nil
            default:
                return event
            }
        }
    }

    private func removeKeyMonitor() {
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
            self.keyMonitor = nil
        }
    }

    /// ⌘1–⌘9 jump straight to a result, as TextExpander's search does.
    private var quickPickShortcuts: some View {
        ForEach(0..<9, id: \.self) { i in
            Button("") {
                if hits.indices.contains(i) { onPick(hits[i].snippet) }
            }
            .keyboardShortcut(
                KeyEquivalent(Character("\(i + 1)")),
                modifiers: .command
            )
            .opacity(0)
            .frame(width: 0, height: 0)
        }
    }

    private var searchField: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .font(.title3)
            TextField(loc.s("search.placeholder"), text: $query)
                .textFieldStyle(.plain)
                .font(.title3)
                .focused($searchFocused)
                .onSubmit { expandSelected() }
            if !query.isEmpty {
                Button {
                    query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help(loc.s("common.clear"))
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var resultList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(Array(hits.enumerated()), id: \.element.id) { index, hit in
                        InlineSearchRow(
                            hit: hit,
                            index: index,
                            isSelected: index == selection
                        )
                        .id(index)
                        .contentShape(Rectangle())
                        .onTapGesture { onPick(hit.snippet) }
                        .onHover { inside in
                            if inside { selection = index }
                        }
                    }
                }
            }
            .onChange(of: selection) { new in
                withAnimation(.easeOut(duration: 0.12)) {
                    proxy.scrollTo(new, anchor: .center)
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.largeTitle)
                .foregroundStyle(.tertiary)
            Text(loc.s("snippets.empty.noMatch", query))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var footer: some View {
        HStack(spacing: 14) {
            hint("↑↓", loc.s("search.hint.navigate"))
            hint("↩", loc.s("search.hint.expand"))
            hint("⌘1–9", loc.s("search.hint.jump"))
            hint("esc", loc.s("search.hint.close"))
            Spacer()
            Text(loc.s("search.count", hits.count, store.allSnippets.count))
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    private func hint(_ key: String, _ label: String) -> some View {
        HStack(spacing: 4) {
            Text(key)
                .font(.system(.caption2, design: .monospaced))
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 4))
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private func move(_ delta: Int) {
        guard !hits.isEmpty else { return }
        selection = min(max(0, selection + delta), hits.count - 1)
    }

    private func expandSelected() {
        guard hits.indices.contains(selection) else { return }
        onPick(hits[selection].snippet)
    }
}

private struct InlineSearchRow: View {
    let hit: SearchHit
    let index: Int
    let isSelected: Bool

    private var preview: String {
        hit.snippet.content
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespaces)
    }

    var body: some View {
        HStack(spacing: 10) {
            Text(hit.snippet.abbreviation)
                .font(.system(.body, design: .monospaced))
                .bold()
                .foregroundStyle(isSelected ? .white : .primary)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(
                    isSelected ? Color.white.opacity(0.2) : Color.secondary.opacity(0.12),
                    in: RoundedRectangle(cornerRadius: 4)
                )

            VStack(alignment: .leading, spacing: 1) {
                if !hit.snippet.label.isEmpty {
                    Text(hit.snippet.label)
                        .lineLimit(1)
                        .foregroundStyle(isSelected ? .white : .primary)
                }
                Text(preview)
                    .lineLimit(1)
                    .font(.caption)
                    .foregroundStyle(isSelected ? Color.white.opacity(0.8) : Color.secondary)
            }

            Spacer(minLength: 8)

            Text(hit.groupName)
                .font(.caption2)
                .foregroundStyle(isSelected ? Color.white.opacity(0.75) : Color.secondary)
                .lineLimit(1)

            if index < 9 {
                Text("⌘\(index + 1)")
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(isSelected ? Color.white.opacity(0.75) : Color.secondary.opacity(0.6))
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .background(isSelected ? Color.accentColor : Color.clear)
    }
}
