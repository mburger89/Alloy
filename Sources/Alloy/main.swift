import AlloyCore
import AlloyKit
import AppKit
import Foundation
import MetalUI

// Usage: Alloy [<project-dir> [<file-to-open>]]. Without arguments the last opened project is used,
// else an open-folder panel asks. "/" and the home directory are never a project root.
// ALLOY_DATA_DIR (set by the benchmark) replaces Application Support for settings, ledgers and sessions.
let appSupport = AlloySettings.appSupportDirectory(default: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0])
var settings = AlloySettings.load(appSupport: appSupport)
let home = NSHomeDirectory()

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
func makeWorkspace(root: URL, file: String?) -> Workspace? {
    guard case .open(let checked, _) = choose([root.path]).choice else { return nil }
    // The controller's settings are the current ones (a theme chosen on the launcher included), not the stale copy
    // loaded at startup.
    let current = themeController.settingsForNewWorkspace(lastProjectPath: checked.path)
    try? current.save(appSupport: appSupport)
    settings = current
    let workspace = Workspace(projectRoot: checked, appSupport: appSupport, settings: current,
                              loginPATH: { ClaudeLocator.loginShell().path })
    themeController.bind(workspace)
    // Language servers start lazily, on the first open of a file one handles; they stop with the sessions on quit.
    LSPCoordinator.installLive(on: workspace, loginPATH: { ClaudeLocator.loginShell().path })
    workspace.startWatching()
    workspace.openFilePath = file
    return workspace
}

// AppKit and Metal, text through CoreText. Closing the window quits.
let app = try App()
// The theme is installed on the app before any window opens (the launcher included), so there is no flash of the
// default look. The controller lives for the whole process: it watches the themes folder.
let themeController = ThemeController(appSupport: appSupport, settings: settings, host: app,
                                      watcher: FSEventsSource(root: ThemeLibrary.userDirectory(appSupport: appSupport)))
// The one place Alloy writes under `.claude`, and only when the user clicks "Install theme skill" in Settings.
themeController.skillInstaller = ThemeSkillInstaller(home: FileManager.default.homeDirectoryForCurrentUser)
themeController.folderOpener = { NSWorkspace.shared.open($0) }
// The system's own appearance (the windows' scheme follows the forced one, so it can't answer this).
themeController.systemScheme = { NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? .dark : .light }
let arguments = Array(CommandLine.arguments.dropFirst())
let initial = choose(arguments)
let model: LauncherModel
if case .open(let root, let file) = initial.choice, let workspace = makeWorkspace(root: root, file: file) {
    model = LauncherModel(workspace: workspace)
} else {
    model = LauncherModel()
}
let window = try app.openWindow(title: "Alloy", size: alloyWindowSize, minSize: Size(width: Pixels(900), height: Pixels(500)),
                           windowStyle: .hiddenTitleBar) {
    launcherRoot(model: model, themes: themeController)
}

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

// The app menu's Settings… (⌘,) and the Go menu; see alloyCommands.
app.commands { alloyCommands(model: model) }

// Closing the window or quitting stops every claude process first.
installWindowShutdown(on: window, model: model)
app.onTerminateRequest = { model.shutdownRequested { app.replyToTerminateRequest($0) } }

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
        if case .open(let root, _) = picked.choice, let workspace = makeWorkspace(root: root, file: nil) {
            model.adopt(workspace)
            await workspace.restore()
        } else {
            model.message = picked.reason ?? "That folder can't be used as a project."
        }
    }
}

if let workspace = model.workspace {
    Task { await workspace.restore() }
} else if !arguments.isEmpty, let reason = initial.reason {
    model.message = reason
} else {
    model.chooseFolder?()
}
app.run()
