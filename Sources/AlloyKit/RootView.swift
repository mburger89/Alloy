import AlloyCore
import MetalUI

public let alloyWindowSize = Size(width: Pixels(1200), height: Pixels(800))

/// Ideal width of the file panel, the trailing column. alloy-bench scrolls at the panel's centre, 180 pt (half this)
/// from the window's right edge (`TargetApp.alloyFilePanelCentreFromRight` in Bench/Sources/BenchCore/Targets.swift):
/// change both together.
public let alloyFilePanelIdealWidth = Pixels(360)

/// The window's one root element, rebuilt every frame: sidebar | chat | file panel.
@MainActor
public func rootView(workspace: Workspace, themes: ThemeController? = nil) -> some Element {
    VStack(spacing: 0) {
        AlloyScreen(workspace: workspace, themes: themes).equatable()
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(.chatFill)
}

struct AlloyScreen: Component {
    let workspace: Workspace
    /// The theme controller Settings picks themes through (nil in tests that don't exercise themes).
    var themes: ThemeController?
    /// Per-session UI state, kept here so it outlives the chat column's per-session identity.
    @State var store = SessionUIStore()
    /// The code panel's per-document state and highlight engine.
    @State var panel = CodePanelStore()
    /// Quick-open (⌘P), shared by the global keys and the file panel.
    @State var quickOpen = QuickOpenModel()
    /// The Settings view, shown over the chat column.
    @State var showSettings = false
    /// The message field had the keyboard when Settings opened.
    @State var settingsRestoresComposer = false

    /// Opening Settings remembers whether the message field had the keyboard; closing gives it back.
    private var settingsBinding: Binding<Bool> {
        let workspace = workspace, store = store
        let shown = $showSettings
        return Binding(get: { shown.wrappedValue }, set: { open in
            let composer = workspace.sessions.first { $0.id == workspace.selectedSessionID }
                .map { store.entry(for: $0, workspace: workspace).composer }
            if open, !shown.wrappedValue { settingsRestoresComposer = composer?.hasFocus ?? false }
            if !open, shown.wrappedValue, settingsRestoresComposer { composer?.focusRequest += 1 }
            shown.wrappedValue = open
        })
    }

    var content: some ElementGroup {
        let _ = BodyProbe.hit("AlloyScreen")
        let workspace = workspace, quickOpen = quickOpen
        let settingsShown = settingsBinding
        // The app menu's "Settings…" (⌘,) opens the view the sidebar's gear used to: detect `claude` on first open, and
        // leave an open Settings open.
        let _: Void = workspace.openSettings = {
            if !settingsShown.wrappedValue { Task { await workspace.detectClaude() } }
            settingsShown.wrappedValue = true
        }
        ZStack {
            HSplitView {
                SidebarView(workspace: workspace).equatable()
                    .frame(minWidth: Pixels(200), idealWidth: Pixels(250), maxWidth: Pixels(380))
                VStack(spacing: 0) {
                    if let themes { ThemeBar(themes: themes) }
                    CoordinationNotice(workspace: workspace)
                    ZStack {
                        ChatView(workspace: workspace, store: store).equatable()
                        if showSettings { SettingsView(workspace: workspace, themes: themes, close: { settingsShown.wrappedValue = false }) }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .frame(minWidth: Pixels(320), maxWidth: .infinity)
                FilePanelView(workspace: workspace, store: store, panel: panel, quickOpen: quickOpen).equatable()
                    .frame(minWidth: Pixels(240), idealWidth: alloyFilePanelIdealWidth, maxWidth: Pixels(800))
            }
            .splitViewAutosaveName("alloy-main")
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            GlobalKeys(workspace: workspace, quickOpen: quickOpen)
            // Esc closes Settings wherever the focus is (a click on a session row focuses the list), after the focused
            // view declined the key.
            if showSettings {
                Button("Close Settings") { settingsShown.wrappedValue = false }
                    .keyboardShortcut(.cancelAction)
                    .frame(width: Pixels(0), height: Pixels(0))
                    .opacity(0)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
    }
}

/// Each button carries an identifier (`global-key-<name>`). The group is `accessibilityHidden`, and MetalUI leaves
/// hidden elements out of the accessibility tree, so the ids are not observable there (tests drive the shortcuts by key).
///
/// ⌘P, ⌘W, ⌃Tab, ⌃⇧Tab and ⌘1-9 as button shortcuts. A shortcut runs only after the focused view declined the key,
/// so a text field mid-IME-composition (which owns every key then) never triggers one, and the panel's own ⌘F (an
/// `onKeyPress`) and the code view's ⌘G still win. ⌘F and ⌘G are deliberately not registered here.
struct GlobalKeys: Component {
    let workspace: Workspace
    let quickOpen: QuickOpenModel

    var content: some ElementGroup {
        let workspace = workspace, quickOpen = quickOpen
        HStack(spacing: Pixels(0)) {
            Button("Quick Open") {
                if quickOpen.isShowing { quickOpen.hide() } else { quickOpen.show(workspace: workspace) }
            }
            .keyboardShortcut("p", modifiers: .primary)
            .accessibilityIdentifier("global-key-quick-open")
            // Esc closes quick-open first; a tab never closes under it.
            Button("Close Tab") { if !quickOpen.isShowing { workspace.closeActiveTab() } }
                .keyboardShortcut("w", modifiers: .primary)
                .accessibilityIdentifier("global-key-close-tab")
            Button("Next Tab") { workspace.cycleTab(1) }
                .keyboardShortcut(.tab, modifiers: .control)
                .accessibilityIdentifier("global-key-next-tab")
            Button("Previous Tab") { workspace.cycleTab(-1) }
                .keyboardShortcut(.tab, modifiers: [.control, .shift])
                .accessibilityIdentifier("global-key-previous-tab")
            ForEach(1...9, id: \.self) { n in
                Button("Tab \(n)") { workspace.selectTab(number: n) }
                    .keyboardShortcut(KeyEquivalent(Character(String(n))), modifiers: .primary)
                    .accessibilityIdentifier("global-key-tab-\(n)")
            }
        }
        .frame(width: Pixels(0), height: Pixels(0))
        .opacity(0)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
