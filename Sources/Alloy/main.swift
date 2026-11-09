import AlloyCore
import AlloyKit
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
    settings.lastProjectPath = checked.path
    try? settings.save(appSupport: appSupport)
    let workspace = Workspace(projectRoot: checked, appSupport: appSupport, settings: settings,
                              loginPATH: { ClaudeLocator.loginShell().path })
    workspace.startWatching()
    workspace.openFilePath = file
    return workspace
}

// AppKit and Metal, text through CoreText. Closing the window quits.
let app = try App()
let arguments = Array(CommandLine.arguments.dropFirst())
let initial = choose(arguments)
let model: LauncherModel
if case .open(let root, let file) = initial.choice, let workspace = makeWorkspace(root: root, file: file) {
    model = LauncherModel(workspace: workspace)
} else {
    model = LauncherModel()
}
let window = try app.openWindow(title: "Alloy", size: alloyWindowSize, minSize: Size(width: Pixels(900), height: Pixels(500))) {
    launcherRoot(model: model)
}

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
