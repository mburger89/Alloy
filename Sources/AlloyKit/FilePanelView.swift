import AlloyLSP
import AlloyCore
import Foundation
import MetalUI

/// The Go to Definition menu item's shortcut: plain F12 (`keyboardShortcut` with a key alone defaults to Cmd).
@MainActor public let goToDefinitionShortcut = KeyboardShortcut(FilePanelView.f12, modifiers: [])

/// The right panel: the active tab's file in a `CodeView` (editable, with the inline diff of session edits). The
/// container and its accessibility identifiers are the bench contract (`file-panel`, `file-panel-path`,
/// `file-panel-message`).
struct FilePanelView: Component {
    let workspace: Workspace
    let store: SessionUIStore
    let panel: CodePanelStore
    let quickOpen: QuickOpenModel

    /// The function keys the panel handles (`NSF8FunctionKey`, `NSF12FunctionKey`); MetalUI names no function keys.
    static let f8 = KeyEquivalent("\u{f70b}")
    static let f12 = KeyEquivalent("\u{f70f}")

    var content: some ElementGroup {
        let _ = BodyProbe.hit("FilePanelView")
        VStack(alignment: .leading, spacing: 0) {
            if !workspace.tabs.isEmpty { FileTabStrip(workspace: workspace).equatable() }
            if quickOpen.isShowing { QuickOpenField(workspace: workspace, model: quickOpen) }
            if let path = workspace.activeTab {
                let document = workspace.document(path)
                let view = document.flatMap { panel.view(for: $0) }
                FilePanelHeader(workspace: workspace, path: path, document: document, view: view).equatable()
                if let notice = workspace.notices.last(where: { $0.path == path }) {
                    FilePanelNotice(workspace: workspace, notice: notice)
                }
                Divider()
                if let message = workspace.tabMessages[path] {
                    FilePanelMessage(text: message)
                } else if let document, let view {
                    CodePanel(workspace: workspace, store: store, document: document, view: view).equatable()
                        .id(document.id.uuidString)
                } else {
                    FilePanelMessage(text: "Loading\u{2026}")
                }
            } else {
                FilePanelMessage(text: "Select a changed file to see it here.")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(.panelFill)
        // Per-document state is made when a document appears or is replaced (never while rendering).
        .onChange(of: workspace.activeTab.flatMap { workspace.document($0)?.id }, initial: true) {
            panel.attach(workspace: workspace)
            if let path = workspace.activeTab, let document = workspace.document(path) { panel.ensureView(for: document) }
        }
        // A request for another tab's caret must not move the user once they have left it.
        .onChange(of: workspace.activeTab) { panel.cancelDefinition(); workspace.codePanelFocused = false }
        .onChange(of: workspace.tabs) { panel.prune(keeping: workspace.tabs) }
        // A document replaced behind a background tab: its old view is closed now, not when the tab is next shown.
        .onChange(of: workspace.tabs.map { workspace.document($0)?.id }) { panel.refreshReplaced(workspace: workspace) }
        // Cmd-F (Ctrl-F off macOS) from the code panel; a text field elsewhere, such as the composer, keeps the key.
        .onKeyPress(keys: ["f"], phases: .down) { press in
            guard press.modifiers == .primary, let path = workspace.activeTab, let document = workspace.document(path),
                  let view = panel.view(for: document) else { return .ignored }
            view.showFind()
            return .handled
        }
        // F8 / Shift-F8: the next / previous problem of the code panel's file.
        .onKeyPress(keys: [Self.f8], phases: [.down, .repeat]) { press in
            guard press.modifiers.isEmpty || press.modifiers == .shift, let path = workspace.activeTab,
                  let document = workspace.document(path), let view = panel.view(for: document) else { return .ignored }
            view.stepProblem(press.modifiers.isEmpty ? 1 : -1)
            return .handled
        }
        // F12: go to the definition of the symbol at the caret.
        .onKeyPress(keys: [Self.f12], phases: .down) { press in
            guard press.modifiers.isEmpty, let path = workspace.activeTab, let document = workspace.document(path),
                  panel.view(for: document) != nil else { return .ignored }
            panel.goToDefinition(workspace: workspace)
            return .handled
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("file-panel")
    }
}

/// The open files as tabs (MetalUI `TabStrip`, gaps G4, G13). A tab's button is `tab-<path>` and its close button
/// `tab-close-<path>`; the strip is the group "Tabs" and the container is `file-tabs`.
struct FileTabStrip: Component {
    let workspace: Workspace

    var content: some ElementGroup {
        let _ = BodyProbe.hit("FileTabStrip")
        let workspace = workspace
        let tabs = workspace.tabs
        let titles = Self.titles(tabs)
        let items = zip(tabs, titles).map { path, title in
            TabStripItem(id: path, title: title, icon: Image(systemName: "doc.text"),
                         isDirty: workspace.document(path)?.tabDirty == true,
                         accent: Self.accent(path: path, workspace: workspace),
                         accessibilityIdentifier: "tab-\(path)", closeAccessibilityIdentifier: "tab-close-\(path)")
        }
        let selection = Binding<String>(get: { workspace.activeTab ?? tabs.first ?? "" },
                                        set: { workspace.activeTab = $0 })
        VStack(spacing: 0) {
            TabStrip(selection: selection, tabs: items)
                .onCloseTab { path in workspace.requestClose(path) }
                .onMoveTab { from, to in workspace.moveTab(from: from, to: to) }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("file-tabs")
    }

    /// The file name, or the whole path when another open tab has the same name.
    static func titles(_ paths: [String]) -> [String] {
        let names = paths.map { ($0 as NSString).lastPathComponent }
        return zip(paths, names).map { path, name in names.filter { $0 == name }.count > 1 ? path : name }
    }

    /// The colour of the last session that edited the file (the same colour as its gutter bars); nil when none did.
    static func accent(path: String, workspace: Workspace) -> Color? {
        workspace.lastSessionEditor(of: path).map { authorColor($0, sessions: workspace.sessions) }
    }
}

struct FilePanelMessage: Component {
    let text: String
    var content: some ElementGroup {
        Text(verbatim: text).font(size: 12).foregroundColor(.mutedInk)
            .padding(inset(12, 12))
            .accessibilityIdentifier("file-panel-message")
    }
}

/// The path, a dirty dot, why the file is read-only, find and the inline / side-by-side toggle.
struct FilePanelHeader: Component {
    let workspace: Workspace
    let path: String
    let document: EditorDocument?
    let view: OpenDocumentView?

    var content: some ElementGroup {
        let _ = BodyProbe.hit("FilePanelHeader")
        HStack(spacing: Pixels(8)) {
            Text(verbatim: path).font(size: 12).accessibilityIdentifier("file-panel-path")
            if document?.tabDirty == true {
                Circle().fill(Color.mutedInk).frame(width: Pixels(7), height: Pixels(7))
                    .accessibilityIdentifier("file-panel-dirty")
            }
            if let view { DefinitionMessage(view: view).equatable() }
            Spacer()
            if case .readOnly(let reason)? = document?.state {
                Text(verbatim: "Read-only \u{2014} \(reason)").font(size: 11).foregroundColor(.mutedInk)
                    .accessibilityIdentifier("file-panel-read-only")
            }
            ServerStatusLabel(workspace: workspace, path: path).equatable()
            DiagnosticCountsBadge(workspace: workspace, path: path).equatable()
            if let document, let view {
                Button { view.showFind() } label: {
                    Image(systemName: "magnifyingglass").font(.system(size: 13)).padding(Pixels(3))
                }
                .buttonStyle(.plain)
                .help("Find")
                .accessibilityLabel("Find")
                .accessibilityIdentifier("find-button")
                Picker("Diff layout", selection: Binding(get: { document.diffMode }, set: { document.diffMode = $0 })) {
                    Text("Inline").tag(DiffMode.inline)
                    Text("Side by side").tag(DiffMode.sideBySide)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .accessibilityIdentifier("diff-mode-toggle")
            }
        }
        .padding(inset(12, 8))
    }
}

/// The error and warning counts of the file. The only reader of the diagnostics' counts model, so a publish that
/// changes no count re-runs nothing (typing never does).
struct DiagnosticCountsBadge: Component {
    let workspace: Workspace
    let path: String

    var content: some ElementGroup {
        let _ = BodyProbe.hit("DiagnosticCountsBadge")
        // Only this path's box is read: another file's change re-runs nothing here.
        let counts = (workspace.languageServices as? LSPCoordinator)?.diagnostics.counts.counts(for: path)
        HStack(spacing: Pixels(6)) {
            if let counts, counts.errors > 0 {
                Text(verbatim: counts.errors == 1 ? "1 error" : "\(counts.errors) errors").font(size: 11).foregroundColor(.errorInk)
                    .accessibilityIdentifier("file-panel-errors")
            }
            if let counts, counts.warnings > 0 {
                Text(verbatim: counts.warnings == 1 ? "1 warning" : "\(counts.warnings) warnings").font(size: 11).foregroundColor(.warningInk)
                    .accessibilityIdentifier("file-panel-warnings")
            }
        }
    }
}

/// The language server serving the file and what it is doing ("rust-analyzer starting\u{2026}", "rust-analyzer", "not
/// installed", "failed"); nothing when no server serves it. The only reader of the status model, which changes only
/// when a server's state does, so typing re-runs nothing here.
struct ServerStatusLabel: Component {
    let workspace: Workspace
    let path: String

    var content: some ElementGroup {
        let _ = BodyProbe.hit("ServerStatusLabel")
        if let entry = (workspace.languageServices as? LSPCoordinator)?.status.byPath[path], let text = Self.text(entry.name, entry.state) {
            Text(verbatim: text).font(size: 11).foregroundColor(Self.isProblem(entry.state) ? .warningInk : .mutedInk)
                .accessibilityIdentifier("file-panel-lsp-status")
        }
    }

    static func text(_ name: String, _ state: ServerState) -> String? {
        switch state {
        case .starting: "\(name) starting\u{2026}"
        case .ready: name
        case .notInstalled: "\(name) not installed"
        case .failed: "\(name) failed"
        case .stopped: nil
        }
    }

    static func isProblem(_ state: ServerState) -> Bool {
        switch state {
        case .notInstalled, .failed: true
        default: false
        }
    }
}

/// The go-to-definition message of the file's view ("No definition found"). The only reader of that message, so a
/// change re-runs just this.
struct DefinitionMessage: Component {
    let view: OpenDocumentView

    var content: some ElementGroup {
        let _ = BodyProbe.hit("DefinitionMessage")
        if let text = view.definitionMessage {
            Text(verbatim: text).font(size: 11).foregroundColor(.mutedInk)
                .accessibilityIdentifier("file-panel-definition-message")
        }
    }
}

/// The newest message about this file's text (a session edit that overlapped unsaved typing, a deletion).
struct FilePanelNotice: Component {
    let workspace: Workspace
    let notice: Notice

    var content: some ElementGroup {
        let workspace = workspace, notice = notice
        let isError = notice.kind == .error
        HStack(spacing: Pixels(8)) {
            Text(verbatim: notice.text).font(size: 11).foregroundColor(isError ? .errorInk : .warningInk)
                .accessibilityIdentifier("file-panel-notice")
            Spacer()
            Button("Dismiss") { workspace.dismiss(notice) }
                .accessibilityIdentifier("file-panel-notice-dismiss")
        }
        .padding(inset(12, 4))
        .background(isError ? Color.errorTint : Color.warningTint)
    }
}
