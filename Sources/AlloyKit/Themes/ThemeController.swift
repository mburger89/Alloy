import AlloyCore
import Foundation
import MetalUI
import Observation

/// Cancels its task when the owner goes away, so a watcher never outlives its controller.
/// `@unchecked Sendable` is safe: `task` is only ever touched on the main actor (the controller is `@MainActor`) except
/// in `deinit`, which runs after the last reference is gone, so no other access can be running.
private final class TaskBox: @unchecked Sendable {
    var task: Task<Void, Never>?
    deinit { task?.cancel() }
}

/// A draft shown on the whole app without touching settings (Ruling 6).
public struct ThemePreview: Equatable {
    public var name: String
    public var session: UUID
    public var draft: ThemeFile
    public var resolved: ResolvedTheme
    /// The saved theme's id once the previewing session has saved a file equal to the draft.
    public var savedID: String?
    public var findings: [ContrastFinding]
}

/// Which setting an activation fills.
public enum ActivationSlot: Equatable, Sendable { case single, light, dark }

/// An activation held back because the theme has contrast findings (Ruling 9).
public struct PendingActivation: Equatable {
    public var themeID: String
    public var findingCount: Int
    public var slot: ActivationSlot
}

public enum ThemeActivationError: Error, Equatable { case unknownTheme(String) }

/// Chooses, applies and live-reloads the app theme. A change only assigns the host's themes (a repaint); it never
/// touches sessions, tabs or scroll positions.
///
/// The controller exists before any workspace does (the launcher is themed too). Until `bind` it keeps the settings
/// itself and saves them directly; afterwards the workspace owns them and `choose` goes through `updateSettings`.
@MainActor @Observable
public final class ThemeController: ThemeWorkshop {
    public private(set) var library: ThemeLibrary
    /// Set when the chosen theme isn't available and a fallback was applied; the settings file is left as it is.
    public private(set) var notice: String?
    /// The draft on screen, if any. One at a time, app-wide.
    public private(set) var preview: ThemePreview?
    /// An activation waiting for the user's answer to the contrast warning.
    public private(set) var pendingActivation: PendingActivation?
    /// The look the views draw with: the shown theme's style with the user's appearance overrides on top. Stored, and
    /// written only when it changes, so a view that reads it re-runs on a real change and never per apply.
    public private(set) var style: AppearanceStyle = .defaults
    /// How many library reloads ran (tests use it to check that event bursts coalesce).
    @ObservationIgnored public private(set) var reloadCount = 0

    @ObservationIgnored private var workspace: Workspace?
    @ObservationIgnored private var unboundSettings: AlloySettings
    @ObservationIgnored private let appSupport: URL
    @ObservationIgnored private let host: ThemeHost
    @ObservationIgnored private let directory: URL
    /// Installs the theme skill from Settings. Nil (the default) hides the button, so nothing can write to a home
    /// directory unless the app, or a test with a temporary home, supplies one.
    @ObservationIgnored public var skillInstaller: ThemeSkillInstaller?
    @ObservationIgnored private let watcherBox = TaskBox()
    @ObservationIgnored private var reloading = false
    @ObservationIgnored private var reloadAgain = false

    /// What "Open themes folder" hands the folder to. The app sets it to the workspace opener (AlloyKit stays free of
    /// AppKit); tests set their own. Does nothing until set.
    @ObservationIgnored public var folderOpener: @MainActor (URL) -> Void = { _ in }

    /// The settings in force: the workspace's once bound.
    public var currentSettings: AlloySettings { workspace?.settings ?? unboundSettings }

    /// Loads the user themes once, synchronously (this runs before the first window, so nothing waits on it), applies
    /// the chosen theme and starts watching the themes folder. A nil `watcher` means no live reload.
    public init(appSupport: URL, settings: AlloySettings, host: ThemeHost, watcher: FileChangeSource?) {
        self.appSupport = appSupport
        unboundSettings = settings
        self.host = host
        directory = ThemeLibrary.userDirectory(appSupport: appSupport)
        library = ThemeLibrary.load(builtIns: BuiltInThemes.all, userDirectory: directory, previous: nil)
        apply()
        guard let watcher else { return }
        let directory = self.directory
        watcherBox.task = Task { [weak self] in
            // FSEvents is not relied on to report a folder that does not exist yet, so it is created first.
            await Task.detached { try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }.value
            for await _ in watcher.changes() {
                if Task.isCancelled { break }
                guard let self else { break }
                self.requestReload()
            }
        }
    }

    /// A controller for an existing workspace.
    public convenience init(workspace: Workspace, host: ThemeHost, watcher: FileChangeSource?) {
        self.init(appSupport: workspace.appSupport, settings: workspace.settings, host: host, watcher: watcher)
        self.workspace = workspace
        workspace.themeWorkshop = self
    }

    /// The settings to open a workspace with: the current ones, with the last project replaced.
    public func settingsForNewWorkspace(lastProjectPath: String?) -> AlloySettings {
        var s = currentSettings
        s.lastProjectPath = lastProjectPath
        return s
    }

    /// Hands settings over to `workspace`. A theme chosen before the workspace existed is kept.
    public func bind(_ workspace: Workspace) {
        var s = workspace.settings
        let mine = unboundSettings
        if s.themeMode != mine.themeMode || s.theme != mine.theme || s.lightTheme != mine.lightTheme || s.darkTheme != mine.darkTheme {
            s.themeMode = mine.themeMode; s.theme = mine.theme; s.lightTheme = mine.lightTheme; s.darkTheme = mine.darkTheme
            try? workspace.updateSettings(s)
        }
        self.workspace = workspace
        workspace.themeWorkshop = self
        apply()
    }

    /// Runs a reload now, or, when one is under way, asks for exactly one more after it. A burst of events costs two.
    private func requestReload() {
        if reloading { reloadAgain = true; return }
        reloading = true
        Task { [weak self] in
            while let self {
                // A short pause lets the rest of a burst arrive, so it is folded into this reload.
                try? await Task.sleep(for: .milliseconds(30))
                self.reloadAgain = false
                await self.reload()
                if !self.reloadAgain { break }
            }
            self?.reloading = false
        }
    }

    /// Stops watching. Also happens when the controller is released.
    public func stop() {
        watcherBox.task?.cancel()
        watcherBox.task = nil
    }

    @ObservationIgnored private var isApplying = false

    /// Recomputes ``style`` from the shown theme and the settings' overrides. `apply()` calls it; call it directly
    /// after changing only the appearance overrides.
    public func refreshStyle() {
        var next = (shownTheme?.style ?? .defaults).applying(currentSettings.appearance)
        // The Glass setting, unless `ALLOY_GLASS=0` forces glass off. Read here, where the style is resolved, so it adds no element.
        next.glass = currentSettings.glass && GlassLook.glassEnabledAtLaunch
        if next != style {
            style = next
            // The window and island paints derive from the style: install the themes again (apply() installs its own).
            if !isApplying { apply() }
        }
    }

    /// Installs the chosen theme(s) on the host.
    public func apply() {
        isApplying = true
        // `isApplying` stays set through `refreshStyle()` so a style change inside it does not install the themes again.
        defer { refreshStyle(); isApplying = false }
        let settings = currentSettings
        var notes: [String] = []
        func resolved(_ id: String, fallback: String, label: String) -> ResolvedTheme? {
            if let r = library.resolve(id) { return r }
            notes.append("Theme \"\(id)\" isn't available; using \(label).")
            return library.resolve(fallback) ?? library.resolve("alloy-dark")
        }
        switch settings.themeMode {
        case .single:
            if let r = resolved(settings.theme, fallback: "dracula", label: "Dracula") {
                let theme = ThemeApplier.theme(for: r, overrides: settings.appearance)
                host.lightTheme = theme
                host.darkTheme = theme
                host.preferredColorScheme = r.appearance == .dark ? .dark : .light
            }
        case .matchSystem:
            if let light = resolved(settings.lightTheme, fallback: "alloy-light", label: "Alloy Light") {
                host.lightTheme = ThemeApplier.theme(for: light, overrides: settings.appearance)
            }
            if let dark = resolved(settings.darkTheme, fallback: "dracula", label: "Dracula") {
                host.darkTheme = ThemeApplier.theme(for: dark, overrides: settings.appearance)
            }
            host.preferredColorScheme = nil
        }
        notice = notes.isEmpty ? nil : notes.joined(separator: " ")
        // A preview sits on top of the user's theme, whatever the theme mode (Ruling 6).
        if let preview {
            let theme = ThemeApplier.theme(for: preview.resolved, overrides: settings.appearance)
            host.lightTheme = theme
            host.darkTheme = theme
            host.preferredColorScheme = preview.resolved.appearance == .dark ? .dark : .light
        }
    }

    /// Re-reads the themes folder off the main actor, then applies on it. A file that no longer parses keeps its last
    /// good version.
    public func reload() async {
        reloadCount += 1
        let directory = self.directory, previous = library
        let loaded = await Task.detached {
            ThemeLibrary.load(builtIns: BuiltInThemes.all, userDirectory: directory, previous: previous)
        }.value
        library = loaded
        apply()
    }

    /// Saves the choice through `Workspace.updateSettings` (which relaunches nothing for theme-only changes), then applies.
    public func choose(mode: ThemeMode? = nil, theme: String? = nil, light: String? = nil, dark: String? = nil,
                       clearingAppearance: Bool = false) throws {
        var s = currentSettings
        if clearingAppearance { s.appearance = AppearanceOverrides() }
        if let mode { s.themeMode = mode }
        if let theme { s.theme = theme }
        if let light { s.lightTheme = light }
        if let dark { s.darkTheme = dark }
        if let workspace {
            // `updateSettings` tells the workshop, whose `refreshStyle()` would install the themes; `apply()` below does it once.
            isApplying = true
            defer { isApplying = false }
            try workspace.updateSettings(s)
        } else {
            try s.save(appSupport: appSupport)
        }
        unboundSettings = s
        apply()
    }

    /// The themes folder's path, as the installed skill names it.
    public var themesFolderPath: String { directory.path }

    /// Dracula in one theme mode, and the appearance overrides (gutter, corners, opacity, blur) cleared.
    public func backToDracula() throws { try choose(mode: .single, theme: "dracula", clearingAppearance: true) }

    /// Creates the folder when it is missing, then hands its URL to `open`.
    public func openThemesFolder(using open: (URL) -> Void) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        open(directory)
    }

    // MARK: ThemeWorkshop

    /// An appearance-only settings change leaves the theme alone, so only the style needs recomputing.
    public func settingsDidChange() { refreshStyle() }

    public var slotCatalog: [ThemeSlotInfo] { ThemeSlots.all.map { ThemeSlotInfo(name: $0.name, purpose: $0.purpose) } }

    /// The scheme the system is in, for `shownTheme` in match-system mode. The app wires it to the real appearance.
    @ObservationIgnored public var systemScheme: @MainActor () -> ColorScheme = { .dark }

    public var shownTheme: ResolvedTheme? {
        if let preview { return preview.resolved }
        let s = currentSettings
        switch s.themeMode {
        case .single: return library.resolve(s.theme) ?? library.resolve("dracula")
        case .matchSystem:
            return systemScheme() == .dark
                ? library.resolve(s.darkTheme) ?? library.resolve("dracula")
                : library.resolve(s.lightTheme) ?? library.resolve("alloy-light")
        }
    }

    public func preview(_ draft: ThemeFile, resolved: ResolvedTheme, session: UUID) {
        preview = ThemePreview(name: draft.name, session: session, draft: draft, resolved: resolved, savedID: nil,
                               findings: ThemeContrast.findings(resolved))
        apply()
    }

    public func didSave(_ saved: SavedTheme, file: ThemeFile, session: UUID) async {
        await reload()
        guard var p = preview, p.session == session else { return }
        if Self.sameContent(p.draft, file) {
            p.savedID = saved.id
        } else if p.savedID == saved.id {
            p.savedID = nil // the same file now holds something else
        }
        preview = p
    }

    /// Ruling 7: equal means the same appearance, base, colours, session colours and style.
    private static func sameContent(_ a: ThemeFile, _ b: ThemeFile) -> Bool {
        a.appearance == b.appearance && a.base == b.base && a.colors == b.colors && a.sessionColors == b.sessionColors
            && a.style == b.style
    }

    public func discardPreview() {
        guard preview != nil else { return }
        preview = nil
        apply()
    }

    /// Safe to call more than once for a session: only the session that owns the current preview discards it.
    public func themeSessionEnded(_ session: UUID) {
        guard preview?.session == session else { return }
        discardPreview()
    }

    /// Tests only: runs after Keep's save and before it activates, to land a newer preview mid-save.
    @ObservationIgnored var afterKeepSave: (@MainActor () -> Void)?

    /// Saves the preview if it isn't saved yet, then activates it through the contrast warning.
    public func keepPreview() async throws {
        guard let p = preview else { return }
        // A remembered save only counts while the file in the library still holds the previewed draft.
        var id = p.savedID.flatMap { saved in
            library.entry(saved).map { Self.sameContent($0.file, p.draft) } == true ? saved : nil
        }
        if id == nil {
            let store = ThemeStore(appSupport: appSupport)
            let builtIns = BuiltInThemes.all
            let draft = p.draft, name = p.name, session = p.session
            id = try await Task.detached { try store.save(draft, name: name, session: session, builtIns: builtIns).id }.value
            await reload()
        }
        afterKeepSave?()
        guard let id else { return }
        let single = currentSettings.themeMode == .single
        try request(theme: single ? id : nil,
                    light: !single && p.draft.appearance == .light ? id : nil,
                    dark: !single && p.draft.appearance == .dark ? id : nil)
        // Only the preview this Keep was for goes away; a newer one (from any session) stays.
        if preview == p { discardPreview() }
    }

    /// The checked way to activate: themes with contrast findings wait for `confirmActivation()`.
    public func request(theme: String? = nil, light: String? = nil, dark: String? = nil) throws {
        let (id, slot): (String, ActivationSlot)
        if let theme { (id, slot) = (theme, .single) } else if let light { (id, slot) = (light, .light) } else if let dark { (id, slot) = (dark, .dark) } else { return }
        guard let resolved = library.resolve(id) else { throw ThemeActivationError.unknownTheme(id) }
        let findings = ThemeContrast.findings(resolved)
        if findings.isEmpty {
            pendingActivation = nil
            try activate(PendingActivation(themeID: id, findingCount: 0, slot: slot))
        } else {
            pendingActivation = PendingActivation(themeID: id, findingCount: findings.count, slot: slot)
        }
    }

    public func confirmActivation() throws {
        guard let pending = pendingActivation else { return }
        pendingActivation = nil
        try activate(pending)
    }

    public func cancelActivation() { pendingActivation = nil }

    private func activate(_ a: PendingActivation) throws {
        switch a.slot {
        case .single: try choose(theme: a.themeID)
        case .light: try choose(light: a.themeID)
        case .dark: try choose(dark: a.themeID)
        }
    }
}
