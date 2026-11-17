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
    /// Where the glass bar reads the look from; nil (tests without themes) draws the defaults.
    var themes: ThemeController?
    /// The glass bar's height with its gutter above and below: the code's top margin. Written only when it changes.
    /// Zero until measured; the first frames use the store's last measured height or the style's estimate, so the code does not jump
    /// when the measurement arrives.
    @State var barHeight: Double = 0

    /// The notice, then the file's message or its code. The code takes `clear` as its top margin; the others as padding.
    @ElementBuilder
    private func fileBody(path: String?, notice: Notice?, document: EditorDocument?, view: OpenDocumentView?,
                          style: AppearanceStyle, clear: Double, noticeClear: Double) -> some ElementGroup {
        let top = Self.topInset(clear)
        if let path {
            if let notice {
                VStack(spacing: 0) { FilePanelNotice(workspace: workspace, notice: notice, style: style) }
                    .padding(Self.topInset(noticeClear))
            }
            if let message = workspace.tabMessages[path] {
                VStack(spacing: 0) { FilePanelMessage(text: message) }.padding(top)
            } else if let document, let view {
                let _ = workspace.selectionRevision
                CodePanel(workspace: workspace, store: store, document: document, view: view, selection: view.selection(in: workspace), topClear: clear).equatable()
                    .id(document.id.uuidString)
            } else {
                VStack(spacing: 0) { FilePanelMessage(text: "Loading\u{2026}") }.padding(top)
            }
        } else {
            VStack(spacing: 0) { FilePanelMessage(text: "Select a changed file to see it here.") }.padding(top)
        }
    }

    private static func topInset(_ top: Double) -> Edges<Pixels> {
        Edges(top: Pixels(Float(top)), right: Pixels(0), bottom: Pixels(0), left: Pixels(0))
    }

    /// The function keys the panel handles (`NSF8FunctionKey`, `NSF12FunctionKey`); MetalUI names no function keys.
    static let f8 = KeyEquivalent("\u{f70b}")
    static let f12 = KeyEquivalent("\u{f70f}")

    var content: some ElementGroup {
        let _ = BodyProbe.hit("FilePanelView")
        let style = themes?.style ?? .defaults
        let path = workspace.activeTab
        let document = path.flatMap { workspace.document($0) }
        let view = document.flatMap { panel.view(for: $0, in: .chat) }
        let showsBar = !workspace.tabs.isEmpty || path != nil
        let barHeight = $barHeight
        let notice = path.flatMap { path in workspace.notices.last(where: { $0.path == path }) }
        // The bar floats over the top of the panel. Rows that are not the code (quick open, a notice, a message) start
        // below it; the code itself scrolls under it, its first line one gutter below the bar.
        let known = barHeight.wrappedValue > 0 ? barHeight.wrappedValue : (store.metrics.filePanelBarHeight ?? style.filePanelBarHeightEstimate)
        let clear = showsBar ? known : 0
        let picker = (workspace.gitServices as? GitCoordinator)?.branchPicker
        let pickerShowing = !quickOpen.isShowing && (picker?.isShowing ?? false)
        let belowBar = quickOpen.isShowing || pickerShowing || notice != nil
        let quickOpenTop = Self.topInset(clear)
        let bodyClear = belowBar ? 0 : clear
        VStack(alignment: .leading, spacing: 0) {
            if quickOpen.isShowing {
                VStack(spacing: 0) { QuickOpenField(workspace: workspace, model: quickOpen) }.padding(quickOpenTop)
            } else if pickerShowing, let picker {
                VStack(spacing: 0) { QuickOpenField(source: picker) }.padding(quickOpenTop)
            }
            fileBody(path: path, notice: notice, document: document, view: view, style: style, clear: bodyClear, noticeClear: quickOpen.isShowing || pickerShowing ? 0 : clear)
        }
        // The tabs and the header share one glass bar floating over the code.
        .overlay(alignment: .top) {
            if showsBar {
                FilePanelBar(workspace: workspace, path: path, document: document, view: view, style: style, height: barHeight, metrics: store.metrics)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        // Per-document state is made when a document appears or is replaced (never while rendering).
        .onChange(of: workspace.activeTab.flatMap { workspace.document($0)?.id }, initial: true) {
            panel.attach(workspace: workspace)
            if let path = workspace.activeTab, let document = workspace.document(path) { panel.ensureView(for: document, in: .chat) }
        }
        // A request for another tab's caret must not move the user once they have left it.
        .onChange(of: workspace.activeTab) { panel.cancelDefinition(); workspace.codePanelFocused = false }
        // A document replaced behind a background tab: its old view is closed now, not when the tab is next shown.
        .onChange(of: workspace.tabs.map { workspace.document($0)?.id }) { panel.refreshReplaced(workspace: workspace) }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("file-panel")
        .codeKeyHandlers(workspace: workspace, panel: panel, pane: .chat)
    }
}

extension ElementGroup {
    /// The code panel's keys for `pane`'s active tab: Cmd-F (Ctrl-F off macOS) opens find, Cmd-S saves, F8 / Shift-F8 step through
    /// the problems, F12 goes to the definition, Shift-F12 lists the references, Cmd-I shows the hover, Cmd-. lists the quick fixes. A text field elsewhere, such as the composer, keeps its keys.
    func codeKeyHandlers(workspace: Workspace, panel: CodePanelStore, pane: PaneID) -> some ElementGroup {
        self
            .onKeyPress(keys: ["f"], phases: .down) { press in
                guard press.modifiers == .primary, let path = workspace.activeTab(in: pane), let document = workspace.document(path),
                      let view = panel.view(for: document, in: pane) else { return .ignored }
                view.showFind()
                return .handled
            }
            // Cmd-S: a deliberate save of the pane's active tab, so the format-on-save hook runs. A key handler, not a
            // hidden button: a button would add elements to every frame.
            .onKeyPress(keys: ["s"], phases: .down) { press in
                guard press.modifiers == .primary, workspace.activeTab(in: pane) != nil else { return .ignored }
                workspace.requestSaveActive(in: pane)
                return .handled
            }
            // Cmd-I: the hover of the symbol at the primary caret.
            .onKeyPress(keys: ["i"], phases: .down) { press in
                guard press.modifiers == .primary, let path = workspace.activeTab(in: pane), let document = workspace.document(path),
                      let view = panel.view(for: document, in: pane), view.hoverAttached(editable: document.state == .editable) else { return .ignored }
                view.showHover(at: nil, workspace: workspace)
                return .handled
            }
            // Cmd-.: the quick fixes at the caret (a key handler, as for Cmd-I).
            .onKeyPress(keys: ["."], phases: .down) { press in
                guard press.modifiers == .primary, let path = workspace.activeTab(in: pane), let document = workspace.document(path),
                      let view = panel.view(for: document, in: pane), let scheduler = view.scheduler, view.features.codeAction else { return .ignored }
                scheduler.showActions()
                return .handled
            }
            // Shift-Cmd-O: the symbols of the pane's file, even when no server offers them. A key handler, not a hidden
            // button: a button would add elements to every frame.
            .onKeyPress(keys: ["o", "O"], phases: .down) { press in
                guard press.modifiers == [.primary, .shift], workspace.activeTab(in: pane) != nil,
                      let quickOpen = panel.quickOpen else { return .ignored }
                quickOpen.showSymbols(workspace: workspace)
                return .handled
            }
            // F8 / Shift-F8: the next / previous problem of the pane's file.
            .onKeyPress(keys: [FilePanelView.f8], phases: [.down, .repeat]) { press in
                guard press.modifiers.isEmpty || press.modifiers == .shift, let path = workspace.activeTab(in: pane),
                      let document = workspace.document(path), let view = panel.view(for: document, in: pane) else { return .ignored }
                view.stepProblem(press.modifiers.isEmpty ? 1 : -1)
                return .handled
            }
            // F12: go to the definition of the symbol at the caret.
            // Shift-F12: the references of the symbol at the caret.
            .onKeyPress(keys: [FilePanelView.f12], phases: .down) { press in
                guard press.modifiers.isEmpty || press.modifiers == .shift, let path = workspace.activeTab(in: pane),
                      let document = workspace.document(path), panel.view(for: document, in: pane) != nil else { return .ignored }
                if press.modifiers == .shift {
                    guard let quickOpen = panel.quickOpen else { return .ignored }
                    panel.findReferences(workspace: workspace, quickOpen: quickOpen, pane: pane)
                } else {
                    panel.goToDefinition(workspace: workspace, pane: pane)
                }
                return .handled
            }
    }
}

/// The glass bar floating over the top of the panel: the tabs and the header. Its height with the gutter above and below
/// is the code's top margin, written to `height` only when it changes.
struct FilePanelBar: Component {
    let workspace: Workspace
    let path: String?
    let document: EditorDocument?
    let view: OpenDocumentView?
    let style: AppearanceStyle
    let height: Binding<Double>
    /// Remembers the measured height for the next panel's first frame.
    let metrics: SessionUIStore.BarMetrics

    var content: some ElementGroup {
        let _ = BodyProbe.hit("FilePanelBar")
        let height = height
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                if !workspace.tabs.isEmpty { FileTabStrip(workspace: workspace, style: style).equatable() }
                if let path { FilePanelHeader(workspace: workspace, path: path, document: document, view: view).equatable() }
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("file-panel-bar")
            .segmentedPickerShape(style.buttonShape)
            .glassControl(style: style, cornerRadius: style.cornerRadius)
        }
        .padding(style.gutterInsets)
        .onGeometryChange(for: Double.self, of: { Double($0.size.height.value) }) { new in
            if height.wrappedValue != new { height.wrappedValue = new }
            metrics.filePanelBarHeight = new
        }
    }
}

/// The open files as tabs (MetalUI `TabStrip`, gaps G4, G13). A tab's button is `tab-<path>` and its close button
/// `tab-close-<path>`; the strip is the group "Tabs" and the container is `file-tabs`.
struct FileTabStrip: Component {
    let workspace: Workspace
    /// The selected tab's shape follows the style's pill buttons; part of the identity.
    let style: AppearanceStyle

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
                .selectedTabShape(style.tabSelectionShape)
                // Inside the glass bar: no band of its own, and the selected tab is a pill like the buttons.
                .stripBackground(.clear)
                .selectedTabFill(.color(Color.glassRim))
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

/// The accessibility ids and wording of a header: Chat's (`file-panel-*`) or one group's (`code-group-*-<id>`).
struct HeaderIDs: Equatable {
    let path: String
    let dirty: String
    let readOnly: String
    let find: String
    let presentation: String
    let presentationLabel: String
    /// Whether the picker offers "Plain" (a group's default) besides Inline and Side by side.
    let offersPlain: Bool

    static let chat = HeaderIDs(path: "file-panel-path", dirty: "file-panel-dirty", readOnly: "file-panel-read-only",
                                find: "find-button", presentation: "diff-mode-toggle", presentationLabel: "Diff layout",
                                offersPlain: false)

    static func group(_ id: UUID) -> HeaderIDs {
        HeaderIDs(path: "code-group-path-\(id)", dirty: "code-group-dirty-\(id)", readOnly: "code-group-read-only-\(id)",
                  find: "code-group-find-\(id)", presentation: "code-group-presentation-\(id)",
                  presentationLabel: "Presentation", offersPlain: true)
    }
}

/// The path, a dirty dot, why the file is read-only, find and the presentation picker, for Chat's panel or an editor group.
struct FilePanelHeader: Component {
    let workspace: Workspace
    let path: String
    let document: EditorDocument?
    let view: OpenDocumentView?
    var pane: PaneID = .chat
    var ids: HeaderIDs = .chat

    var content: some ElementGroup {
        let _ = BodyProbe.hit("FilePanelHeader")
        let workspace = workspace, path = path, pane = pane, ids = ids
        HStack(spacing: Pixels(8)) {
            // The path gives up space first (priority 0, the rest 1) and truncates in the middle, so the file name stays.
            Text(verbatim: path).font(size: 12).lineLimit(1).truncationMode(.middle)
                .accessibilityIdentifier(ids.path)
            if document?.tabDirty == true {
                Circle().fill(Color.mutedInk).frame(width: Pixels(7), height: Pixels(7))
                    .accessibilityIdentifier(ids.dirty)
            }
            if let view { DefinitionMessage(view: view).equatable() }
            Spacer()
            if case .readOnly(let reason)? = document?.state {
                Text(verbatim: "Read-only \u{2014} \(reason)").font(size: 11).foregroundColor(.mutedInk).lineLimit(1)
                    .layoutPriority(1)
                    .accessibilityIdentifier(ids.readOnly)
            }
            ServerStatusLabel(workspace: workspace, path: path).equatable()
            DiagnosticCountsBadge(workspace: workspace, path: path).equatable()
            if document != nil, let view {
                Button { view.showFind() } label: {
                    Image(systemName: "magnifyingglass").font(.system(size: 13)).padding(Pixels(3))
                }
                .buttonStyle(.plain)
                .layoutPriority(1)
                .help("Find")
                .accessibilityLabel("Find")
                .accessibilityIdentifier(ids.find)
                Picker(ids.presentationLabel, selection: Binding(get: { workspace.presentation(of: path, in: pane) },
                                                                 set: { workspace.setPresentation($0, of: path, in: pane) })) {
                    if ids.offersPlain { Text("Plain").tag(Presentation.plain) }
                    Text("Inline").tag(Presentation.inline)
                    Text("Side by side").tag(Presentation.sideBySide)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .layoutPriority(1)
                .accessibilityIdentifier(ids.presentation)
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
                Text(verbatim: counts.errors == 1 ? "1 error" : "\(counts.errors) errors").font(size: 11).foregroundColor(.errorInk).lineLimit(1)
                    .accessibilityIdentifier("file-panel-errors")
            }
            if let counts, counts.warnings > 0 {
                Text(verbatim: counts.warnings == 1 ? "1 warning" : "\(counts.warnings) warnings").font(size: 11).foregroundColor(.warningInk).lineLimit(1)
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
        let lsp = workspace.languageServices as? LSPCoordinator
        let main = lsp?.status.byPath[path]
        let linters = lsp?.status.linters[path] ?? []
        let isProblem = main.map { Self.isProblem($0.state) } ?? false
        if let text = Self.text(main: main, linters: linters) {
            Text(verbatim: text).font(size: 11).foregroundColor(isProblem ? .warningInk : .mutedInk)
                .lineLimit(1).layoutPriority(1)
                .accessibilityIdentifier("file-panel-lsp-status")
        }
        ForEach(Self.failedLinterEntries(linters), id: \.id) { entry in
            Text(verbatim: entry.text).font(size: 11).foregroundColor(.errorInk).lineLimit(1).layoutPriority(1)
                .accessibilityIdentifier("file-panel-linter-failed")
        }
    }

    /// The main server's text, then ` \u{00B7} ` and the names of the ready linters (`Pyright \u{00B7} Ruff`); nil when there is nothing.
    static func text(main: (name: String, state: ServerState)?, linters: [(id: String, name: String, state: ServerState)]) -> String? {
        var parts: [String] = []
        if let main, let text = text(main.name, main.state) { parts.append(text) }
        parts += linters.filter { $0.state == .ready }.map(\.name)
        return parts.isEmpty ? nil : parts.joined(separator: " \u{00B7} ")
    }

    /// `"Ruff failed"` for each failed linter. Starting, missing and stopped linters show nothing.
    static func failedLinters(_ linters: [(id: String, name: String, state: ServerState)]) -> [String] {
        failedLinterEntries(linters).map(\.text)
    }

    /// The failed linters with their ids: two linters may share a display name, so the id keys the rows.
    static func failedLinterEntries(_ linters: [(id: String, name: String, state: ServerState)]) -> [(id: String, text: String)] {
        linters.compactMap { if case .failed = $0.state { (id: $0.id, text: "\($0.name) failed") } else { nil } }
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
            Text(verbatim: text).font(size: 11).foregroundColor(.mutedInk).lineLimit(1).layoutPriority(1)
                .accessibilityIdentifier("file-panel-definition-message")
        }
    }
}

/// The newest message about this file's text (a session edit that overlapped unsaved typing, a deletion).
struct FilePanelNotice: Component {
    let workspace: Workspace
    let notice: Notice
    var style: AppearanceStyle = .defaults

    var content: some ElementGroup {
        let workspace = workspace, notice = notice
        let isError = notice.kind == .error
        HStack(spacing: Pixels(8)) {
            Text(verbatim: notice.text).font(size: 11).foregroundColor(isError ? .errorInk : .warningInk)
                .accessibilityIdentifier("file-panel-notice")
            Spacer()
            Button("Dismiss") { workspace.dismiss(notice) }
                .buttonStyle(PillButtonStyle(style: style))
                .accessibilityIdentifier("file-panel-notice-dismiss")
        }
        .padding(inset(12, 4))
        .background(isError ? Color.errorTint : Color.warningTint)
    }
}
