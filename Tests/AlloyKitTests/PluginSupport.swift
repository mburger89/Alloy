import AlloyCore
@testable import AlloyKit
import AlloyPlugins
import AlloyTestSupport
import Foundation
import MetalUI

/// A temporary folder holding plugin source folders, and a coordinator bound to a workspace rig.
@MainActor
final class PluginRig {
    let rig: Rig
    let sources: URL
    let coordinator: PluginCoordinator
    let themes: ThemeController

    @MainActor final class Host: ThemeHost {
        var lightTheme: Theme = .light
        var darkTheme: Theme = .dark
        var preferredColorScheme: ColorScheme?
    }

    init(rig: Rig = Rig(), pathDirs: [String] = [], clock: any AutosaveClock = SystemAutosaveClock(),
         probe: any PluginProcessProbe = LiveProcessProbe(), limits: PluginLimits = PluginLimits(), scripted: Bool = true) {
        self.rig = rig
        sources = rig.root.appendingPathComponent("plugin-sources")
        try? FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)
        themes = ThemeController(workspace: rig.workspace, host: Host(), watcher: nil)
        themes.stop()
        let workspace = rig.workspace
        coordinator = PluginCoordinator(paths: PluginPaths(appSupport: workspace.appSupport),
                                        registry: CommandRegistry(workspace: { workspace }), themes: themes, pathDirs: { pathDirs },
                                        clock: clock, probe: probe, limits: limits, scriptedPluginsSupported: scripted)
        coordinator.bind(workspace)
    }

    var paths: PluginPaths { PluginPaths(appSupport: rig.workspace.appSupport) }

    /// Writes `<sources>/<id>` with the manifest text and `files` (path to contents; `*.sh` is executable).
    @discardableResult
    func source(_ id: String, manifest: String, files: [String: String] = [:]) -> URL {
        let dir = sources.appendingPathComponent(id)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? manifest.write(to: dir.appendingPathComponent("alloy-plugin.json"), atomically: true, encoding: .utf8)
        for (path, contents) in files {
            let url = dir.appendingPathComponent(path)
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? contents.write(to: url, atomically: true, encoding: .utf8)
            if path.hasSuffix(".sh") { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path) }
        }
        return dir
    }

    static let midnight = ##"{"name":"Midnight","appearance":"dark","base":"dracula","colors":{"accent":"#112233"}}"##

    @discardableResult
    func themePack(_ id: String = "dev.example.themes", name: String = "Themes") -> URL {
        source(id, manifest: #"{"id":"\#(id)","name":"\#(name)","version":"1.0.0","contributes":{"themes":[{"path":"themes/midnight.json"}]}}"#,
               files: ["themes/midnight.json": Self.midnight])
    }

    @discardableResult
    func serverPack(_ id: String, name: String, command: String = "fake-a") -> URL {
        source(id, manifest: """
        {"id":"\(id)","name":"\(name)","version":"1.0.0","permissions":["process.spawn"],
         "contributes":{"languageServers":{"fake":{"command":"\(command)"}}}}
        """)
    }

    /// Synchronous install for the rig closures that cannot await: the folder is copied and the catalog adopted.
    func installNow(_ source: URL) throws {
        let workspace = rig.workspace
        let installer = PluginInstaller(paths: paths, pathDirs: [])
        let manifest = try installer.installFolder(source, installed: workspace.settings.plugins)
        var s = workspace.settings
        var entry = s.plugins[manifest.id] ?? PluginSetting(source: .folder(path: source.path))
        entry.version = manifest.version
        s.plugins[manifest.id] = entry
        try workspace.updateSettings(s)
        coordinator.adopt(catalog: PluginCatalog.scan(paths.plugins, pathDirs: []))
    }

    /// A scripted plugin run by the fake (its folder is written straight into the plugin directory), switched on and granted.
    /// Returns its folder; the fake logs every message to `log.jsonl` there.
    @discardableResult
    func fake(_ id: String, script: JSONValue = .object([:]), permissions: [String] = [], activation: [String] = [],
              enable: Bool = true) throws -> URL {
        let folder = try writeFakePlugin(id: id, in: paths.plugins, permissions: permissions, activation: activation, script: script)
        let workspace = rig.workspace
        var s = workspace.settings
        s.plugins[id] = PluginSetting(source: .folder(path: folder.path))
        s.plugins[id]?.version = "1.0.0"
        try workspace.updateSettings(s)
        coordinator.adopt(catalog: PluginCatalog.scan(paths.plugins, pathDirs: [fakePluginDirectory]))
        if enable { try coordinator.enable(id) }
        return folder
    }

    func row(_ id: String) -> PluginRowState? { coordinator.status.rows.first { $0.id == id } }
}
