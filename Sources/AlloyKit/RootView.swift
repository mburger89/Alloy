import AlloyCore
import Foundation
import MetalUI

public let alloyWindowSize = Size(width: Pixels(1200), height: Pixels(800))

/// Ideal width of the file panel, the trailing column. alloy-bench scrolls at the panel's centre, 180 pt (half this)
/// from the window's right edge (`TargetApp.alloyFilePanelCentreFromRight` in Bench/Sources/BenchCore/Targets.swift):
/// change both together.
public let alloyFilePanelIdealWidth = Pixels(360)

/// The window's one root element, rebuilt every frame: sidebar | chat | file panel.
@MainActor
public func rootView(workspace: Workspace, themes: ThemeController? = nil, center: CommandCenter) -> some Element {
    center.bind(workspace)
    return VStack(spacing: 0) {
        AlloyScreen(workspace: workspace, themes: themes, center: center).equatable()
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background { WindowBackdropView(style: themes?.style ?? .defaults).equatable() }
}

/// What is behind everything: the theme's window background and, while the style is see-through, the window material
/// (`containerBackground(_:for: .window)`: the window turns non-opaque with a behind-window blur of the desktop). The
/// background is drawn at the style's tint alpha so the desktop shows through the gutters and islands; at island opacity 1
/// there is no material and the colour is opaque. Reduce Transparency makes MetalUI draw the material as opaque grey and
/// this draws the colour opaque. Equatable on the style so it re-runs only when the look changes.
struct WindowBackdropView: Component, Equatable {
    let style: AppearanceStyle
    @Environment(\.accessibilityReduceTransparency) var reduceTransparency

    nonisolated static func == (a: Self, b: Self) -> Bool { a.style == b.style }

    /// The diagonal gradient, top-leading to bottom-trailing: a static fill, rasterised once per size.
    private func gradient(_ start: Color, _ end: Color) -> LinearGradient {
        LinearGradient(colors: [start, end], startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    var content: some ElementGroup {
        let _ = BodyProbe.hit("WindowBackdropView")
        let seeThrough = style.windowSeeThrough
        if let image = style.backgroundImage, image.exists {
            // The image replaces the gradient, and under Glass the see-through desktop: it is drawn opaque.
            BackgroundImageLayer(image: image, dim: style.backgroundImageDim).equatable()
        } else if seeThrough {
            // One fill: the tint and the shade folded into the window paint (an opaque colour under Reduce Transparency).
            if style.backgroundGradient {
                // The gradient is the same tint layer: tinted and shaded at both ends, opaque colours under Reduce Transparency.
                gradient(reduceTransparency ? .windowBackground : .windowPaint, reduceTransparency ? .windowBackgroundEnd : .windowPaintEnd)
                    .containerBackground(.thinMaterial, for: .window)
            } else {
                (reduceTransparency ? Color.windowBackground : Color.windowPaint)
                    .containerBackground(.thinMaterial, for: .window)
            }
        } else if style.backgroundGradient {
            gradient(.windowBackground, .windowBackgroundEnd)
        } else {
            Color.windowBackground
        }
    }
}

/// Long edge, in pixels, the background image is decoded at: it fills a window under a dim and glass, so 2560 covers a full-screen Retina window's visible detail.
let alloyBackgroundImageMaxPixelSize = 2560

/// The theme's background image, cropped to fill the window and dimmed by the window colour. A static fill: it re-runs only
/// when the file, the dim or the style changes, never while typing or streaming. The file is decoded off the main thread, once
/// per file; until it arrives the window colour shows.
struct BackgroundImageLayer: Component, Equatable {
    let image: BackgroundImage
    let dim: Double
    @State var bitmap: ImageBitmap?

    nonisolated static func == (a: Self, b: Self) -> Bool { a.image == b.image && a.dim == b.dim }

    /// The file decoded no larger than `alloyBackgroundImageMaxPixelSize` on its long edge (never upscaled).
    nonisolated static func decode(path: String) -> ImageBitmap? {
        ImageBitmap(contentsOfFile: path, maxPixelSize: alloyBackgroundImageMaxPixelSize)
    }

    var content: some ElementGroup {
        let _ = BodyProbe.hit("BackgroundImageLayer")
        let path = image.path
        ZStack {
            Color.windowBackground
            if let bitmap {
                Image(decorative: bitmap, scale: 1).resizable().scaledToFill()
            }
            Color.windowBackground.opacity(dim)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
        .task(id: image) {
            let decoded = await Task.detached(priority: .utility) { Self.decode(path: path) }.value
            if !Task.isCancelled { bitmap = decoded }
        }
    }
}

struct AlloyScreen: Component {
    let workspace: Workspace
    /// The theme controller Settings picks themes through (nil in tests that don't exercise themes).
    var themes: ThemeController?
    /// Per-session UI state, kept here so it outlives the chat column's per-session identity.
    @State var store = SessionUIStore()
    /// The code panel's per-document state and highlight engine.
    @State var panel = CodePanelStore()
    /// The shared registry and quick-open (⌘P) model, used by the global keys and the file panel.
    let center: CommandCenter
    /// Split sizes, kept in the project's `ui-state.json`.
    @State var splitStore: UIStateSplitStore

    init(workspace: Workspace, themes: ThemeController? = nil, center: CommandCenter) {
        self.workspace = workspace; self.themes = themes; self.center = center
        _splitStore = State(wrappedValue: UIStateSplitStore(workspace: workspace))
    }

    var content: some ElementGroup {
        let _ = BodyProbe.hit("AlloyScreen")
        let workspace = workspace, quickOpen = center.quickOpen
        let style = themes?.style ?? .defaults
        ZStack {
            VStack(spacing: 0) {
                TitleIsland(workspace: workspace, quickOpen: quickOpen, style: style).equatable()
                switch workspace.mode {
                case .chat:
                    IslandRow(workspace: workspace, store: store, panel: panel, quickOpen: quickOpen, keymap: center.registry.keymap, themes: themes,
                              style: style).equatable()
                case .code:
                    CodeIslandRow(workspace: workspace, store: store, panel: panel, quickOpen: quickOpen, splitStore: splitStore,
                                  themes: themes, style: style).equatable()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .windowTitleBarMetrics(height: Pixels(Float(style.titleBandHeight)),
                                   controlsLeading: Pixels(Float(style.titleControlsLeading)))
            GlobalKeys(workspace: workspace, registry: center.registry).equatable()
            HeldReconciler(workspace: workspace, panel: panel).equatable()
            PaletteLayer(model: center.palette, titleBandHeight: style.titleBandHeight).equatable()
        }
    }
}

/// Always present, whichever mode is shown: when a tab list or a held document changes (and on first appearance), the
/// views of closed tabs and the services of unheld documents are released. A component of its own so the tab lists
/// invalidate only this, not the screen.
struct HeldReconciler: Component, Equatable {
    let workspace: Workspace
    let panel: CodePanelStore

    nonisolated static func == (a: Self, b: Self) -> Bool { a.workspace === b.workspace && a.panel === b.panel }

    var content: some ElementGroup {
        let workspace = workspace, panel = panel
        Spacer()
            .frame(width: Pixels(0), height: Pixels(0))
            .allowsHitTesting(false)
            .accessibilityHidden(true)
            .onChange(of: workspace.heldSignature(), initial: true) { panel.reconcile(workspace: workspace) }
    }
}

/// The three lower islands in a split view, a component of their own so each island's clipped content is built in a
/// smaller type than the whole window (the one big tree crashes the runtime's metadata instantiation).
struct IslandRow: Component, Equatable {
    let workspace: Workspace
    let store: SessionUIStore
    let panel: CodePanelStore
    let quickOpen: QuickOpenModel
    let keymap: ResolvedKeymap
    var themes: ThemeController?
    let style: AppearanceStyle

    nonisolated static func == (a: Self, b: Self) -> Bool {
        a.workspace === b.workspace && a.store === b.store && a.panel === b.panel && a.quickOpen === b.quickOpen && a.keymap === b.keymap
            && a.themes === b.themes && a.style == b.style
    }

    var content: some ElementGroup {
        let _ = BodyProbe.hit("IslandRow")
        let gutter = Pixels(Float(style.gutter))
        HSplitView {
            SidebarView(workspace: workspace, keymap: keymap).equatable()
                .island(style: style, identifier: "island-sidebar")
                .frame(minWidth: Pixels(200), idealWidth: Pixels(250), maxWidth: Pixels(380))
            ChatIslandBody(workspace: workspace, store: store, themes: themes)
            .island(style: style, identifier: "island-chat")
            .frame(minWidth: Pixels(320), maxWidth: .infinity)
            FilePanelView(workspace: workspace, store: store, panel: panel, quickOpen: quickOpen, themes: themes).equatable()
                .island(style: style, identifier: "island-files")
                .frame(minWidth: Pixels(240), idealWidth: alloyFilePanelIdealWidth, maxWidth: Pixels(800))
        }
        .splitViewAutosaveName("alloy-main")
        // The gutter between the lower islands is the divider's own thickness; the window edge is padding.
        .splitViewDivider(.hidden, thickness: CGFloat(style.gutter))
        .padding(Edges(top: Pixels(0), right: gutter, bottom: gutter, left: gutter))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Each button carries an identifier (`global-key-<name>`). The group is `accessibilityHidden`, and MetalUI leaves
/// hidden elements out of the accessibility tree, so the ids are not observable there (tests drive the shortcuts by key).
///
/// ⌘P, ⌘W, ⌃Tab, ⌃⇧Tab and ⌘1-9 as button shortcuts. A shortcut runs only after the focused view declined the key,
/// so a text field mid-IME-composition (which owns every key then) never triggers one, and the panel's own ⌘F (an
/// `onKeyPress`) and the code view's ⌘G still win. ⌘F and ⌘G are deliberately not registered here.
struct GlobalKeys: Component, Equatable {
    let workspace: Workspace
    let registry: CommandRegistry

    nonisolated static func == (a: Self, b: Self) -> Bool { a.workspace === b.workspace && a.registry === b.registry }

    var content: some ElementGroup {
        // The set of commands and the resolved keys are the only registry state read here; a change to either rebuilds
        // the buttons, a frame without one does nothing.
        let _ = BodyProbe.hit("GlobalKeys")
        let _ = registry.revision
        let _ = registry.keymap.revision
        let registry = registry
        let global = registry.commands.filter { $0.descriptor.binding == .global }
        let inCode = workspace.mode == .code ? registry.commands.filter { $0.descriptor.binding == .globalInCode } : []
        HStack(spacing: Pixels(0)) {
            ForEach(global, id: \.descriptor.id) { command in
                globalKey(command, registry: registry)
            }
            // Chat mode's sidebar button owns ⌘N; Code mode has no sidebar sessions list, so the key lives here.
            ForEach(inCode, id: \.descriptor.id) { command in
                globalKey(command, registry: registry)
            }
        }
        .frame(width: Pixels(0), height: Pixels(0))
        .opacity(0)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    /// No `.disabled`: a disabled command's key still reaches `run(id:)`, which refuses it.
    private func globalKey(_ command: RegisteredCommand, registry: CommandRegistry) -> some Element {
        let descriptor = command.descriptor
        return Button(descriptor.title) { registry.run(id: descriptor.id) }
            .keyboardShortcut(registry.keymap.chord(for: descriptor.id)?.shortcut)
            .accessibilityIdentifier(descriptor.keyID)
    }
}
