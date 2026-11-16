import AlloyCore
import Foundation
import MetalUI

let codeGroupEmptyText = "Open a file with \u{2318}P or from the tree"
/// The empty group text's font size and inset.
let codeGroupEmptyFontSize: Double = 12
let codeGroupEmptyInset = Float(12)

/// One editor group: its glass bar (tab strip and header), then notices, Quick Open's field while this group has focus,
/// and the code of the active tab, or the empty state.
struct EditorGroupView: Component {
    let workspace: Workspace
    let store: SessionUIStore
    let panel: CodePanelStore
    let quickOpen: QuickOpenModel
    let groupID: UUID
    var themes: ThemeController?
    let style: AppearanceStyle
    /// The bar's measured height with its gutters: the code's top margin. Written only when it changes.
    @State var barHeight: Double = 0

    private static func topInset(_ top: Double) -> Edges<Pixels> {
        Edges(top: Pixels(Float(top)), right: Pixels(0), bottom: Pixels(0), left: Pixels(0))
    }

    /// The notice, then the file's message or its code. The code takes `clear` as its top margin; the others as padding.
    @ElementBuilder
    private func fileBody(path: String?, notice: Notice?, document: EditorDocument?, view: OpenDocumentView?,
                          clear: Double, noticeClear: Double, focus: @escaping () -> Void) -> some ElementGroup {
        let top = Self.topInset(clear)
        if let path {
            if let notice {
                VStack(spacing: 0) { FilePanelNotice(workspace: workspace, notice: notice, style: style) }
                    .padding(Self.topInset(noticeClear))
            }
            if let message = workspace.tabMessages[path] {
                VStack(spacing: 0) { FilePanelMessage(text: message) }.padding(top)
            } else if let document, let view {
                CodePanel(workspace: workspace, store: store, document: document, view: view, topClear: clear,
                          codeViewIdentifier: "code-view-\(groupID)", onFocus: focus).equatable()
                    .id(document.id.uuidString)
            } else {
                VStack(spacing: 0) { FilePanelMessage(text: "Loading\u{2026}") }.padding(top)
            }
        } else {
            VStack(spacing: 0) {
                Text(verbatim: codeGroupEmptyText).font(size: codeGroupEmptyFontSize).foregroundColor(.mutedInk)
                    .padding(inset(codeGroupEmptyInset, codeGroupEmptyInset))
                    .accessibilityIdentifier("code-group-empty-\(groupID)")
            }.padding(top)
        }
    }

    var content: some ElementGroup {
        let _ = BodyProbe.hit("EditorGroupView")
        let workspace = workspace, panel = panel, groupID = groupID
        let pane = PaneID.group(groupID)
        let layout = workspace.codeLayout
        let group = layout.groups[groupID]
        let path = group?.activeTab
        let document = path.flatMap { workspace.document($0) }
        let view = document.flatMap { panel.view(for: $0, in: pane) }
        let focused = layout.focusedGroupID == groupID
        let barHeight = $barHeight
        let notice = path.flatMap { path in workspace.notices.last(where: { $0.path == path }) }
        let known = barHeight.wrappedValue > 0 ? barHeight.wrappedValue : (store.metrics.filePanelBarHeight ?? style.filePanelBarHeightEstimate)
        let clear = known
        let showQuickOpen = quickOpen.isShowing && focused
        let belowBar = showQuickOpen || notice != nil
        let focus: () -> Void = { [weak workspace] in workspace?.focusGroup(id: groupID) }
        VStack(alignment: .leading, spacing: 0) {
            if showQuickOpen {
                VStack(spacing: 0) { QuickOpenField(workspace: workspace, model: quickOpen) }.padding(Self.topInset(clear))
            }
            fileBody(path: path, notice: notice, document: document, view: view, clear: belowBar ? 0 : clear,
                     noticeClear: showQuickOpen ? 0 : clear, focus: focus)
        }
        .overlay(alignment: .top) {
            GroupBar(workspace: workspace, groupID: groupID, path: path, document: document, view: view, focused: focused,
                     style: style, height: barHeight, metrics: store.metrics).equatable()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        // Per-document state is made when a document appears or is replaced (never while rendering).
        .onChange(of: path.flatMap { workspace.document($0)?.id }, initial: true) {
            panel.attach(workspace: workspace)
            if let path = workspace.activeTab(in: pane) { workspace.loadIfNeeded(path, in: pane) }
            if let path = workspace.activeTab(in: pane), let document = workspace.document(path) { panel.ensureView(for: document, in: pane) }
        }
        // A request for another tab's caret must not move the user once they have left it.
        .onChange(of: path) { panel.cancelDefinition() }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("code-group-\(groupID)")
        .codeKeyHandlers(workspace: workspace, panel: panel, pane: pane)
    }
}

extension EditorGroupView: Equatable {
    nonisolated static func == (a: Self, b: Self) -> Bool {
        a.workspace === b.workspace && a.store === b.store && a.panel === b.panel && a.quickOpen === b.quickOpen
            && a.groupID == b.groupID && a.themes === b.themes && a.style == b.style
    }
}

/// The glass bar floating over the top of a group: its tabs and header.
struct GroupBar: Component {
    let workspace: Workspace
    let groupID: UUID
    let path: String?
    let document: EditorDocument?
    let view: OpenDocumentView?
    let focused: Bool
    let style: AppearanceStyle
    let height: Binding<Double>
    let metrics: SessionUIStore.BarMetrics

    var content: some ElementGroup {
        let _ = BodyProbe.hit("GroupBar")
        let height = height
        let showsTabs = !workspace.tabs(in: .group(groupID)).isEmpty
        let showsBar = showsTabs || path != nil
        VStack(spacing: 0) {
            if showsBar {
                VStack(alignment: .leading, spacing: 0) {
                    if showsTabs { GroupTabStrip(workspace: workspace, groupID: groupID, focused: focused, style: style).equatable() }
                    if let path { FilePanelHeader(workspace: workspace, path: path, document: document, view: view, pane: .group(groupID),
                                    ids: .group(groupID)).equatable() }
                }
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("code-group-bar-\(groupID)")
                .segmentedPickerShape(style.buttonShape)
                .glassControl(style: style, cornerRadius: style.cornerRadius)
            }
        }
        .padding(style.gutterInsets)
        .onGeometryChange(for: Double.self, of: { Double($0.size.height.value) }) { new in
            if height.wrappedValue != new { height.wrappedValue = new }
            // An empty group draws no bar: its zero height must not replace Chat's measured one.
            if showsBar { metrics.filePanelBarHeight = new }
        }
    }
}

extension GroupBar: Equatable {
    nonisolated static func == (a: Self, b: Self) -> Bool {
        a.workspace === b.workspace && a.groupID == b.groupID && a.path == b.path && a.document === b.document
            && a.view === b.view && a.focused == b.focused && a.style == b.style
    }
}

/// The group's open files as tabs: `group-<id>-tab-<path>` and `group-<id>-tab-close-<path>`, in the container
/// `code-group-tabs-<id>`. The focused group's selected tab is a glass pill; the others' are clear.
struct GroupTabStrip: Component {
    let workspace: Workspace
    let groupID: UUID
    let focused: Bool
    let style: AppearanceStyle

    var content: some ElementGroup {
        let _ = BodyProbe.hit("GroupTabStrip")
        let workspace = workspace, groupID = groupID
        let pane = PaneID.group(groupID)
        let tabs = workspace.tabs(in: pane)
        let titles = FileTabStrip.titles(tabs)
        let items = zip(tabs, titles).map { path, title in
            TabStripItem(id: path, title: title, icon: Image(systemName: "doc.text"),
                         isDirty: workspace.document(path)?.tabDirty == true,
                         accent: FileTabStrip.accent(path: path, workspace: workspace),
                         accessibilityIdentifier: "group-\(groupID)-tab-\(path)",
                         closeAccessibilityIdentifier: "group-\(groupID)-tab-close-\(path)")
        }
        let selection = Binding<String>(get: { workspace.activeTab(in: pane) ?? tabs.first ?? "" },
                                        set: { workspace.focusGroup(id: groupID); workspace.activate($0, in: pane) })
        let select = { (path: String) in selection.wrappedValue = path }
        VStack(spacing: 0) {
            TabStrip(selection: selection, tabs: items)
                .selectedTabShape(style.tabSelectionShape)
                .stripBackground(.clear)
                .selectedTabFill(focused ? .color(Color.glassRim) : .clear)
                .onCloseTab { path in workspace.requestClose(path, in: pane) }
                .onMoveTab { from, to in workspace.moveTab(from: from, to: to, in: pane) }
                // A right click does not select, so each item selects the tab first, then splits the focused group.
                .tabContextMenu { path in
                    Button("Split Right") { select(path); workspace.splitFocused(.horizontal) }
                    Button("Split Down") { select(path); workspace.splitFocused(.vertical) }
                    Button("Close Tab") { workspace.requestClose(path, in: pane) }
                }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("code-group-tabs-\(groupID)")
    }
}

extension GroupTabStrip: Equatable {
    nonisolated static func == (a: Self, b: Self) -> Bool {
        a.workspace === b.workspace && a.groupID == b.groupID && a.focused == b.focused && a.style == b.style
    }
}
