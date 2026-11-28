import Foundation
import AlloyTestSupport
@testable import AlloyPlugins

/// A temporary directory per test, with helpers to write a plugin folder.
final class PluginTestFolder {
    let root: URL
    init() {
        root = TempFiles.url("alloy-plugin-tests")
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    deinit { try? FileManager.default.removeItem(at: root) }

    /// Makes `<root>/<id>` holding `alloy-plugin.json` with `manifest` (JSON text).
    @discardableResult
    func plugin(_ id: String, manifest: String) -> URL {
        let dir = root.appendingPathComponent(id)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? manifest.write(to: dir.appendingPathComponent("alloy-plugin.json"), atomically: true, encoding: .utf8)
        return dir
    }

    func file(_ path: String, in dir: URL, executable: Bool = false, contents: String = "#!/bin/sh\n") {
        let url = dir.appendingPathComponent(path)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? contents.write(to: url, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: executable ? 0o755 : 0o644], ofItemAtPath: url.path)
    }
}

/// Runs plugin processes as they are, so suites that watch a plugin's own log files need no sandbox profile. Only the
/// sandbox suites run through the real backend.
struct PassthroughSandbox: PluginSandboxBackend {
    func wrap(executable: String, arguments: [String], profile: SandboxProfileInput) throws(PluginSandboxError)
        -> (executable: String, arguments: [String]) { (executable, arguments) }

    /// Handed to each `PluginHost` the test builds; nothing global is replaced, so suites cannot leak into each other.
    static var override: PluginSandboxOverride { .backend(PassthroughSandbox()) }
}
