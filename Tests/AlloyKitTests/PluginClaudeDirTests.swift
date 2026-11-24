@testable import AlloyCore
@testable import AlloyKit
@testable import AlloyPlugins
import AlloyRPC
import AlloyTestSupport
import Foundation
import Testing

/// Plugins never cause a write under `~/.claude` or the project's `.claude`: install, enable, state, write, remove and the
/// log are exercised with a temporary home, and no `.claude` appears anywhere.
@MainActor
@Suite(.serialized) struct PluginClaudeDirTests {
    private func claudeDirs(under root: URL) -> [String] {
        guard let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else { return [] }
        return e.compactMap { ($0 as? URL)?.path }.filter { $0.split(separator: "/").contains(".claude") }
    }

    @Test func noPluginPathWritesADotClaude() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("alloy-home-\(UUID().uuidString)").resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let rig = Rig()
        try "a\n".write(to: rig.root.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        let p = PluginRig(rig: rig, pathDirs: [fakePluginDirectory, "/usr/bin", "/bin"], home: home.path)
        let id = "dev.test.dotclaude"
        let source = p.source(id, manifest: #"{"id":"\#(id)","name":"Dot","version":"1.0.0","permissions":["project.read","project.write"]}"#)
        try p.installNow(source)
        _ = try p.fake(id + "2", permissions: ["project.read", "project.write"])
        _ = await p.coordinator.activate(plugin: id + "2", .command)
        let state = await p.coordinator.answerRequest(from: id, "state/set", .object(["key": .string("k"), "value": .string("v")]))
        guard case .success = state else { Issue.record("state failed"); return }
        for path in [".claude/settings.json", "sub/.claude/x", ".git/hooks/pre-commit", ".Claude/settings.json", "sub/.CLAUDE/x", "ok.txt"] {
            _ = await p.coordinator.answerRequest(from: id, "project/write", .object(["path": .string(path), "text": .string("x")]))
        }
        _ = await p.coordinator.logText(for: id)
        // Removing a plugin deletes its folder and data, and touches nothing under the home directory.
        try await p.coordinator.remove(id)
        try await p.coordinator.remove(id + "2")
        await p.coordinator.shutdown()
        #expect(claudeDirs(under: home).isEmpty, "\(claudeDirs(under: home))")
        #expect(claudeDirs(under: rig.root).isEmpty, "\(claudeDirs(under: rig.root))")
        #expect(claudeDirs(under: rig.workspace.appSupport).isEmpty, "\(claudeDirs(under: rig.workspace.appSupport))")
        #expect(FileManager.default.fileExists(atPath: rig.root.appendingPathComponent("ok.txt").path))
    }
}
