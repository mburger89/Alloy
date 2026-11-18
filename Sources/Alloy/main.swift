import AlloyCore
import AlloyKit
import AppKit
import Foundation
import MetalUI

StartupTrace.mark("main-entered")

// Usage: Alloy [<project-dir> [<file-to-open>]]. Without arguments the last opened project is used,
// else an open-folder panel asks. "/" and the home directory are never a project root.
// ALLOY_DATA_DIR (set by the benchmark) replaces Application Support for settings, ledgers and sessions.
let appSupport = AlloySettings.appSupportDirectory(default: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0])
var settings = AlloySettings.load(appSupport: appSupport)
StartupTrace.mark("settings-loaded")
GitExecutable.configure(gitPath: settings.git.gitPath)
let home = NSHomeDirectory()
StartupTrace.mark("git-configured")

func isDirectory(_ path: String) -> Bool {
    var isDir: ObjCBool = false
    return FileManager.default.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue
}

@MainActor
func choose(_ arguments: [String]) -> (choice: ProjectChoice, reason: String?) {
    ProjectChoice.resolveDetailed(arguments: arguments, settings: settings, isDirectory: isDirectory, home: home,
                                  cwd: FileManager.default.currentDirectoryPath,
                                  resolveSymlinks: ProjectChoice.systemResolver,
                                  fileExists: { FileManager.default.fileExists(atPath: $0) })
}

/// Opens `root` as the project. The choice was already checked; the resolved root is checked once more.
@MainActor
func makeWorkspace(root: URL) -> Workspace? {
    guard case .open(let checked, _) = choose([root.path]).choice else { return nil }
    // The controller's settings are the current ones (a theme chosen on the launcher included), not the stale copy
    // loaded at startup.
    let current = themeController.settingsForNewWorkspace(lastProjectPath: checked.path)
    try? current.save(appSupport: appSupport)
    settings = current
    StartupTrace.mark("makeWorkspace-settings-saved")
    let workspace = Workspace(projectRoot: checked, appSupport: appSupport, settings: current,
                              loginPATH: { ClaudeLocator.loginShell().path })
    themeController.bind(workspace)
    StartupTrace.mark("makeWorkspace-workspace-init-and-theme-bind")
    // Language servers start lazily, on the first open of a file one handles; they stop with the sessions on quit.
    LSPCoordinator.installLive(on: workspace, loginPATH: { ClaudeLocator.loginShell().path })
    StartupTrace.mark("makeWorkspace-lsp-installed")
    GitCoordinator.installLive(on: workspace)
    StartupTrace.mark("makeWorkspace-git-installed")
    workspace.startWatching()
    StartupTrace.mark("makeWorkspace-watching-started")
    return workspace
}

// AppKit and Metal, text through CoreText. Closing the window quits.
let app = try App()
StartupTrace.mark("app-created")
// The theme is installed on the app before any window opens (the launcher included), so there is no flash of the
// default look. The controller lives for the whole process: it watches the themes folder.
let themeController = ThemeController(appSupport: appSupport, settings: settings, host: app,
                                      watcher: FSEventsSource(root: ThemeLibrary.userDirectory(appSupport: appSupport)))
// The one place Alloy writes under `.claude`, and only when the user clicks "Install theme skill" in Settings.
themeController.skillInstaller = ThemeSkillInstaller(home: FileManager.default.homeDirectoryForCurrentUser)
themeController.folderOpener = { NSWorkspace.shared.open($0) }
TerminalLinkHooks.openURL = { NSWorkspace.shared.open($0) }
// The system's own appearance (the windows' scheme follows the forced one, so it can't answer this).
themeController.systemScheme = { NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? .dark : .light }
StartupTrace.mark("theme-controller-ready")
let arguments = Array(CommandLine.arguments.dropFirst())
let initial = choose(arguments)
StartupTrace.mark("project-chosen")
let model: LauncherModel
if case .open(let root, _) = initial.choice, let workspace = makeWorkspace(root: root) {
    model = LauncherModel(workspace: workspace)
} else {
    model = LauncherModel()
}
StartupTrace.mark("workspace-created")
// The registry and quick open, shared by the window and the menu bar. Created before the window.
let center = CommandCenter(launcher: model)
if let workspace = model.workspace { center.bind(workspace) }
StartupTrace.mark("command-center-ready")
center.standardMenuClaims = { app.standardMenuShortcuts() }
// The app menu's Settings… (⌘,) and the Go menu; see alloyCommands. It only needs `app`, so it exists before the window.
let settingsWindow = SettingsWindowController { title, size, minSize, root in
    try app.openWindow(title: title, size: size, minSize: minSize, windowStyle: .hiddenTitleBar) { settingsWindowElement(root) }
}
// The updater starts only in a real bundled app that has a feed URL and a public key (never under `swift run` or in
// tests). Its UI is Alloy's own: a sidebar banner, a Settings section and the menu item below. An update installs
// only on quit or through the banner's "Restart to update", both after the normal shutdown stopped every session.
StartupTrace.mark("settings-window-controller-ready")
let updateModel = UpdateModel()
let sparkleDriver = SparkleDriver()
let updateController = UpdateController(driver: sparkleDriver, model: updateModel, busySessions: {
    model.workspace?.sessions.filter { s in
        switch s.status { case .working, .awaitingPermission: true; default: false }
    }.count ?? 0
}, shutdown: {
    await withCheckedContinuation { continuation in
        if model.shutdownRequested(reply: { _ in continuation.resume() }) == .now { continuation.resume() }
    }
})
sparkleDriver.controller = updateController
sparkleDriver.feedURLOverride = UpdateFeedPolicy.override(info: Bundle.main.infoDictionary ?? [:], environment: ProcessInfo.processInfo.environment)
StartupTrace.mark("sparkle-driver-created")
let updatesEnabled = updateController.start(bundleURL: Bundle.main.bundleURL,
                                            info: Bundle.main.infoDictionary ?? [:],
                                            environment: ProcessInfo.processInfo.environment)
StartupTrace.mark("updater-started")
model.onShutdownComplete = { updateController.applicationWillQuit() }
settingsWindow.updates = updatesEnabled ? updateModel : nil
StartupTrace.mark("before-openWindow")
let window = try app.openWindow(title: "Alloy", size: alloyWindowSize, minSize: Size(width: Pixels(900), height: Pixels(500)),
                           windowStyle: .hiddenTitleBar) {
    launcherRoot(model: model, themes: themeController, updates: updatesEnabled ? updateModel : nil, center: center)
}
StartupTrace.mark("openWindow-returned")

// The benchmark (ALLOY_FRAME_TIMING=1 with ALLOY_DATA_DIR) reads MetalUI's frame timing: it is written on SIGTERM.
// Without the flag nothing is installed and SIGTERM keeps its default behaviour.
// The handler runs on the main queue: if the main thread stays blocked past the harness's 5 s SIGTERM grace period,
// the harness SIGKILLs Alloy and the dump is lost; the harness then simply has no attribution for that run.
var frameTimingTerm: DispatchSourceSignal?
if let dumpURL = FrameTimingRecorder.install(on: window, environment: ProcessInfo.processInfo.environment),
   let timing = window.frameTiming {
    signal(SIGTERM, SIG_IGN)
    let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
    source.setEventHandler {
        MainActor.assumeIsolated { try? FrameTimingRecorder.write(timing, to: dumpURL) }
        exit(0)
    }
    source.resume()
    frameTimingTerm = source
}

StartupTrace.mark("frame-timing-installed")
FrameTimingRecorder.installStartupTrace(on: window)
BuiltinCommands.register(into: center, launcher: model, settings: { settingsWindow }, themes: { themeController })
StartupTrace.mark("builtin-commands-registered")
app.commands {
    alloyCommands(center: center, updates: updatesEnabled ? updateModel : nil, checkForUpdates: { updateController.checkForUpdates() })
}
StartupTrace.mark("app-commands-set")

// Closing the window or quitting stops every claude process first.
installWindowShutdown(on: window, model: model, settings: settingsWindow)
app.onTerminateRequest = { model.shutdownRequested { app.replyToTerminateRequest($0) } }
StartupTrace.mark("shutdown-hooks-installed")

// The panel asks for a folder; cancelling quits, a refused folder or a dialog error explains and asks again.
var choosing = false
model.chooseFolder = {
    guard !choosing, model.workspace == nil else { return }
    choosing = true
    Task { @MainActor in
        defer { choosing = false }
        let urls: [URL]
        do {
            urls = try await window.fileDialogs.openFiles(allowedContentTypes: [.folder])
        } catch {
            model.message = "The folder panel failed: \(error)"
            return
        }
        guard let url = urls.first else { app.terminate(); return }
        let picked = choose([url.path])
        if case .open(let root, _) = picked.choice, let workspace = makeWorkspace(root: root) {
            center.bind(workspace)
            model.adopt(workspace)
            await workspace.restore()
        } else {
            model.message = picked.reason ?? "That folder can't be used as a project."
        }
    }
}

if let workspace = model.workspace {
    // The command-line file opens after the saved layout is back, so it lands in the restored mode's pane.
    let startupFile: String? = if case .open(_, let file) = initial.choice { file } else { nil }
    Task { await workspace.restore(opening: startupFile); StartupTrace.mark("restore-finished") }
} else if !arguments.isEmpty, let reason = initial.reason {
    model.message = reason
} else {
    model.chooseFolder?()
}
StartupTrace.mark("before-app-run")
app.run()
