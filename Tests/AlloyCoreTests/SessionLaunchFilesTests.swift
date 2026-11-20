@testable import AlloyCore
import AlloyTestSupport
import Foundation
import Testing

/// The text of a launch file named by a `--settings` / `--mcp-config` argument.
func launchFileText(_ path: String?) -> String? {
    guard let path, let data = FileManager.default.contents(atPath: path) else { return nil }
    return String(decoding: data, as: UTF8.self)
}

private func mode(_ url: URL) -> Int {
    ((try? FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions]) as? NSNumber)?.intValue ?? -1
}

private final class LHarness: @unchecked Sendable {
    private let lock = NSLock()
    private var _configs: [LaunchConfiguration] = []
    var configs: [LaunchConfiguration] { lock.withLock { _configs } }
    var factory: TransportFactory {
        { [self] cfg in
            lock.withLock { _configs.append(cfg) }
            return ScriptedTransport()
        }
    }
}

@Suite final class SessionLaunchFilesTests {
    private var dirs: [URL] = []
    deinit { dirs.forEach { try? FileManager.default.removeItem(at: $0) } }

    private func tempDir() -> URL {
        let u = FileManager.default.temporaryDirectory.appendingPathComponent("alloy-slf-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        let r = u.resolvingSymlinksInPath()
        dirs.append(r)
        return r
    }

    @Test func writesFilesWith0600InA0700Directory() throws {
        let support = tempDir()
        let files = SessionLaunchFiles(supportDirectory: support)
        let id = UUID()
        let paths = try files.write(sessionID: id, mcpConfig: #"{"m":1}"#, settings: #"{"s":2}"#)
        let mcp = URL(fileURLWithPath: try #require(paths.mcpConfigPath))
        let settings = URL(fileURLWithPath: try #require(paths.settingsPath))
        #expect(launchFileText(mcp.path) == #"{"m":1}"#)
        #expect(launchFileText(settings.path) == #"{"s":2}"#)
        #expect(mode(mcp) == 0o600 && mode(settings) == 0o600)
        #expect(mode(mcp.deletingLastPathComponent()) == 0o700)
        #expect(mode(files.root) == 0o700)
        #expect(mcp.path.hasPrefix(support.path))
    }

    @Test func absentDocumentsGetNoPath() throws {
        let files = SessionLaunchFiles(supportDirectory: tempDir())
        let paths = try files.write(sessionID: UUID(), mcpConfig: "{}", settings: nil)
        #expect(paths.mcpConfigPath != nil && paths.settingsPath == nil)
    }

    @Test func argumentsCarryPathsNotJSON() throws {
        let files = SessionLaunchFiles(supportDirectory: tempDir())
        let id = UUID()
        let secret = "tok-SECRET-123"
        let paths = try files.write(sessionID: id, mcpConfig: #"{"Authorization":"Bearer \#(secret)"}"#,
                                    settings: #"{"hooks":{"x":"\#(secret)"}}"#)
        let c = LaunchConfiguration(executable: URL(fileURLWithPath: "/x/claude"), projectDirectory: URL(fileURLWithPath: "/p"),
                                    sessionID: id, resume: false, settingsArgument: paths.settingsPath,
                                    mcpConfigArgument: paths.mcpConfigPath)
        let args = c.arguments()
        #expect(args == OutboundTests.base + ["--session-id", id.uuidString.lowercased(),
                                              "--settings", try #require(paths.settingsPath),
                                              "--mcp-config", try #require(paths.mcpConfigPath)])
        #expect(!args.contains { $0.contains(secret) })
    }

    @Test func removeDeletesOnlyThatSession() throws {
        for firstA in [true, false] {
            let files = SessionLaunchFiles(supportDirectory: tempDir())
            let a = UUID(), b = UUID()
            let pa = try files.write(sessionID: a, mcpConfig: "{}", settings: "{}")
            let pb = try files.write(sessionID: b, mcpConfig: "{}", settings: "{}")
            files.remove(sessionID: firstA ? a : b)
            let gone = firstA ? pa : pb, kept = firstA ? pb : pa
            #expect(!FileManager.default.fileExists(atPath: try #require(gone.mcpConfigPath)))
            #expect(FileManager.default.fileExists(atPath: try #require(kept.mcpConfigPath)))
            files.remove(sessionID: firstA ? b : a)
            #expect(!FileManager.default.fileExists(atPath: try #require(kept.mcpConfigPath)))
        }
    }

    @Test func removeAllClearsLeftoversFromACrashedRun() throws {
        let support = tempDir()
        let files = SessionLaunchFiles(supportDirectory: support)
        let stray = files.root.appendingPathComponent(UUID().uuidString.lowercased())
        try FileManager.default.createDirectory(at: stray, withIntermediateDirectories: true)
        try Data("old".utf8).write(to: stray.appendingPathComponent("mcp.json"))
        files.removeAll()
        #expect(!FileManager.default.fileExists(atPath: stray.path))
        // Usable again afterwards.
        #expect(try files.write(sessionID: UUID(), mcpConfig: "{}", settings: nil).mcpConfigPath != nil)
    }

    @Test func writeReplacesItsOwnLeftoverWithoutTouchingSiblings() throws {
        let files = SessionLaunchFiles(supportDirectory: tempDir())
        let a = UUID(), b = UUID()
        _ = try files.write(sessionID: b, mcpConfig: "{}", settings: "{}")
        _ = try files.write(sessionID: a, mcpConfig: "{}", settings: "{}")
        let again = try files.write(sessionID: a, mcpConfig: "{\"new\":1}", settings: nil)
        #expect(launchFileText(again.mcpConfigPath) == "{\"new\":1}")
        let dir = URL(fileURLWithPath: try #require(again.mcpConfigPath)).deletingLastPathComponent()
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("settings.json").path))
        #expect(FileManager.default.fileExists(atPath: files.root.appendingPathComponent(b.uuidString.lowercased()).path))
    }

    @Test func refusesASymlinkedLaunchRoot() throws {
        let support = tempDir(), elsewhere = tempDir()
        try FileManager.default.createDirectory(at: support.appendingPathComponent("Alloy"), withIntermediateDirectories: true)
        let files = SessionLaunchFiles(supportDirectory: support)
        try FileManager.default.createSymbolicLink(at: files.root, withDestinationURL: elsewhere)
        #expect(throws: (any Error).self) { try files.write(sessionID: UUID(), mcpConfig: "{}", settings: nil) }
        #expect(try FileManager.default.contentsOfDirectory(atPath: elsewhere.path).isEmpty)
    }

    // MARK: Workspace

    @MainActor private func workspace(_ h: LHarness, support: URL) -> Workspace {
        Workspace(projectRoot: tempDir(), appSupport: support, settings: AlloySettings(),
                  locate: { _ in URL(fileURLWithPath: "/fake/claude") }, makeTransport: h.factory, now: Date.init)
    }

    @Test @MainActor func launchPutsTheTokenInFilesNotArguments() async throws {
        let h = LHarness(), support = tempDir()
        let ws = workspace(h, support: support)
        let s = await ws.newSession(name: "a")
        await ws.settle()
        let c = try #require(h.configs.first)
        let json = try #require(launchFileText(c.mcpConfigArgument))
        let token = String(try #require(json.components(separatedBy: "Bearer ").dropFirst().first?.prefix(while: { $0 != "\"" })))
        #expect(!token.isEmpty)
        #expect(!c.arguments().contains { $0.contains(token) })
        #expect(c.mcpConfigArgument?.hasPrefix(support.path) == true)
        let dir = SessionLaunchFiles(supportDirectory: support).root.appendingPathComponent(s.id.uuidString.lowercased())
        #expect(FileManager.default.fileExists(atPath: dir.path))
        await ws.stop(s.id)
        #expect(!FileManager.default.fileExists(atPath: dir.path))
        await ws.stopAll()
    }

    @Test @MainActor func stopAllAndFailLaunchRemoveTheSessionDirectory() async throws {
        let h = LHarness(), support = tempDir()
        let ws = workspace(h, support: support)
        let a = await ws.newSession(name: "a")
        let b = await ws.newSession(name: "b")
        await ws.settle()
        let root = SessionLaunchFiles(supportDirectory: support).root
        let da = root.appendingPathComponent(a.id.uuidString.lowercased())
        let db = root.appendingPathComponent(b.id.uuidString.lowercased())
        #expect(FileManager.default.fileExists(atPath: da.path) && FileManager.default.fileExists(atPath: db.path))
        ws.failLaunch(a, "boom")
        #expect(!FileManager.default.fileExists(atPath: da.path))
        #expect(FileManager.default.fileExists(atPath: db.path))
        await ws.stopAll()
        #expect(!FileManager.default.fileExists(atPath: db.path))
    }

    @Test @MainActor func launchSweepsACrashedRunsLeftoversOnce() async throws {
        let h = LHarness(), support = tempDir()
        let stray = SessionLaunchFiles(supportDirectory: support).root.appendingPathComponent(UUID().uuidString.lowercased())
        try FileManager.default.createDirectory(at: stray, withIntermediateDirectories: true)
        let ws = workspace(h, support: support)
        let a = await ws.newSession(name: "a")
        await ws.settle()
        #expect(!FileManager.default.fileExists(atPath: stray.path))
        // A second launch does not sweep the first session's live files.
        _ = await ws.newSession(name: "b")
        await ws.settle()
        let da = SessionLaunchFiles(supportDirectory: support).root.appendingPathComponent(a.id.uuidString.lowercased())
        #expect(FileManager.default.fileExists(atPath: da.path))
        await ws.stopAll()
    }

    @Test @MainActor func aWriteFailureFailsTheLaunchInsteadOfInliningJSON() async throws {
        let h = LHarness(), support = tempDir(), elsewhere = tempDir()
        try FileManager.default.createSymbolicLink(at: support.appendingPathComponent("Alloy"), withDestinationURL: elsewhere)
        let ws = workspace(h, support: support)
        let s = await ws.newSession(name: "a")
        await ws.settle()
        guard case .failedToLaunch = s.status else { Issue.record("status \(s.status)"); return }
        #expect(h.configs.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: elsewhere.appendingPathComponent("session-launch").path))
        await ws.stopAll()
    }
}
