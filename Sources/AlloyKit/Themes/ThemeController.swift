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

/// Chooses, applies and live-reloads the app theme. A change only assigns the host's themes (a repaint); it never
/// touches sessions, tabs or scroll positions.
///
/// The controller exists before any workspace does (the launcher is themed too). Until `bind` it keeps the settings
/// itself and saves them directly; afterwards the workspace owns them and `choose` goes through `updateSettings`.
@MainActor @Observable
public final class ThemeController {
    public private(set) var library: ThemeLibrary
    /// Set when the chosen theme isn't available and a fallback was applied; the settings file is left as it is.
    public private(set) var notice: String?
    /// How many library reloads ran (tests use it to check that event bursts coalesce).
    @ObservationIgnored public private(set) var reloadCount = 0

    @ObservationIgnored private var workspace: Workspace?
    @ObservationIgnored private var unboundSettings: AlloySettings
    @ObservationIgnored private let appSupport: URL
    @ObservationIgnored private let host: ThemeHost
    @ObservationIgnored private let directory: URL
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

    /// Installs the chosen theme(s) on the host.
    public func apply() {
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
                let theme = ThemeApplier.theme(for: r)
                host.lightTheme = theme
                host.darkTheme = theme
                host.preferredColorScheme = r.appearance == .dark ? .dark : .light
            }
        case .matchSystem:
            if let light = resolved(settings.lightTheme, fallback: "alloy-light", label: "Alloy Light") {
                host.lightTheme = ThemeApplier.theme(for: light)
            }
            if let dark = resolved(settings.darkTheme, fallback: "dracula", label: "Dracula") {
                host.darkTheme = ThemeApplier.theme(for: dark)
            }
            host.preferredColorScheme = nil
        }
        notice = notes.isEmpty ? nil : notes.joined(separator: " ")
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
    public func choose(mode: ThemeMode? = nil, theme: String? = nil, light: String? = nil, dark: String? = nil) throws {
        var s = currentSettings
        if let mode { s.themeMode = mode }
        if let theme { s.theme = theme }
        if let light { s.lightTheme = light }
        if let dark { s.darkTheme = dark }
        if let workspace {
            try workspace.updateSettings(s)
        } else {
            try s.save(appSupport: appSupport)
        }
        unboundSettings = s
        apply()
    }

    public func backToDracula() throws { try choose(mode: .single, theme: "dracula") }

    /// Creates the folder when it is missing, then hands its URL to `open`.
    public func openThemesFolder(using open: (URL) -> Void) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        open(directory)
    }
}
