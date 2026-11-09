import AlloyCore
import AlloyTestSupport
import Foundation
import Testing

private final class KHarness: @unchecked Sendable {
    private let lock = NSLock()
    private var _transports: [ScriptedTransport] = []
    private var _configs: [LaunchConfiguration] = []
    var transports: [ScriptedTransport] { lock.withLock { _transports } }
    var configs: [LaunchConfiguration] { lock.withLock { _configs } }
    var factory: TransportFactory {
        { [self] cfg in
            let t = ScriptedTransport()
            lock.withLock { _transports.append(t); _configs.append(cfg) }
            return t
        }
    }
}

@Suite final class KnowledgeLaunchTests {
    private var dirs: [URL] = []
    deinit { dirs.forEach { try? FileManager.default.removeItem(at: $0) } }

    private func tempDir() -> URL {
        let u = FileManager.default.temporaryDirectory.appendingPathComponent("alloy-kl-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        let r = u.resolvingSymlinksInPath()
        dirs.append(r)
        return r
    }

    @MainActor
    private func workspace(_ settings: AlloySettings, _ h: KHarness) -> Workspace {
        Workspace(projectRoot: tempDir(), appSupport: tempDir(), settings: settings,
                  locate: { _ in URL(fileURLWithPath: "/fake/claude") }, makeTransport: h.factory, now: Date.init)
    }

    private let tools = ["mcp__alloy__notes_lookup", "mcp__alloy__notes_read", "mcp__alloy__notes_write",
                         "mcp__alloy__sessions_changes", "mcp__alloy__send_message",
                         "mcp__alloy__claim_region", "mcp__alloy__release_region"]

    @Test @MainActor func launchPassesNotesServerGuidanceAndAllowRule() async throws {
        let h = KHarness()
        let ws = workspace(AlloySettings(), h)
        _ = await ws.newSession(name: "a")
        await ws.settle()
        let c = try #require(h.configs.first)
        let json = try #require(c.mcpConfigJSON)
        #expect(json.contains("\"alloy\""))
        #expect(json.contains("\"Authorization\":\"Bearer "))
        #expect(json.contains(try #require(ws.serverURL).absoluteString))
        #expect(c.appendSystemPrompt == Guidance.text)
        #expect(c.allowedTools == tools)
        #expect(c.arguments().contains("--allowedTools"))
        let settings = try #require(c.extraSettingsJSON)
        let token = try #require(json.components(separatedBy: "Bearer ").dropFirst().first?.prefix(while: { $0 != "\"" }))
        #expect(settings == Hooks.settingsJSON(url: try #require(ws.serverURL), token: String(token)))
        #expect(c.arguments().contains("--settings"))
        await ws.stopAll()
    }

    @Test @MainActor func launchPassesHookSettingsOnlyWithSharingOn() async throws {
        let off = KHarness()
        let wsOff = workspace(AlloySettings(shareKnowledge: false), off)
        _ = await wsOff.newSession(name: "a")
        await wsOff.settle()
        #expect(off.configs.first?.extraSettingsJSON == nil)
        #expect(off.configs.first?.arguments().contains("--settings") == false)
        await wsOff.stopAll()

        let failed = KHarness()
        let wsFail = workspace(AlloySettings(), failed)
        wsFail.failServerStartForTesting = true
        _ = await wsFail.newSession(name: "a")
        await wsFail.settle()
        #expect(failed.configs.first?.extraSettingsJSON == nil)
        await wsFail.stopAll()

        let on = KHarness()
        let wsOn = workspace(AlloySettings(askBeforeSharedNotes: true), on)
        _ = await wsOn.newSession(name: "a")
        await wsOn.settle()
        #expect(on.configs.first?.extraSettingsJSON?.contains("\"hooks\"") == true)
        await wsOn.stopAll()
    }

    @Test @MainActor func relaunchWithSharingOffHasNoSettingsArgument() async throws {
        let h = KHarness()
        let ws = workspace(AlloySettings(), h)
        let s = await ws.newSession(name: "a")
        await h.transports[0].emit(.result(TurnResult(subtype: "success", isError: false, costUSD: 0, inputTokens: 0,
                                                       outputTokens: 0, sessionID: "s", terminalReason: nil)))
        await waitUntil("idle with conversation") { s.status == .idle && s.hasConversation }
        #expect(h.configs[0].arguments().contains("--settings"))
        try ws.updateSettings(AlloySettings(shareKnowledge: false))
        await ws.settle()
        let last = try #require(h.configs.last)
        #expect(h.configs.count == 2 && last.resume, "configs \(h.configs.count) resume \(last.resume) status \(s.status)")
        #expect(last.extraSettingsJSON == nil && !last.arguments().contains("--settings"))
        await ws.stopAll()
    }

    @Test @MainActor func askSettingDropsTheAllowRule() async throws {
        let h = KHarness()
        let ws = workspace(AlloySettings(askBeforeSharedNotes: true), h)
        _ = await ws.newSession(name: "a")
        await ws.settle()
        let c = try #require(h.configs.first)
        #expect(c.allowedTools.isEmpty)
        #expect(c.mcpConfigJSON != nil)
        #expect(c.appendSystemPrompt == Guidance.text)
        #expect(!c.arguments().contains("--allowedTools"))
        await ws.stopAll()
    }

    @Test @MainActor func shareKnowledgeOffPassesNothing() async throws {
        let h = KHarness()
        let ws = workspace(AlloySettings(shareKnowledge: false, askBeforeSharedNotes: false), h)
        _ = await ws.newSession(name: "a")
        await ws.settle()
        let c = try #require(h.configs.first)
        #expect(c.mcpConfigJSON == nil)
        #expect(c.appendSystemPrompt == nil)
        #expect(c.allowedTools.isEmpty)
        #expect(c.extraSettingsJSON == nil)
        await ws.stopAll()
    }

    @Test func oldSettingsFileLoadsWithDefaults() throws {
        let dir = tempDir()
        let url = dir.appendingPathComponent("Alloy/settings.json")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(#"{"claudePath":"/opt/claude","lastProjectPath":"/p"}"#.utf8).write(to: url)
        let s = AlloySettings.load(appSupport: dir)
        #expect(s.claudePath == "/opt/claude")
        #expect(s.lastProjectPath == "/p")
        #expect(s.shareKnowledge == true)
        #expect(s.askBeforeSharedNotes == false)
        // New fields round-trip.
        try AlloySettings(shareKnowledge: false, askBeforeSharedNotes: true).save(appSupport: dir)
        let back = AlloySettings.load(appSupport: dir)
        #expect(back.shareKnowledge == false && back.askBeforeSharedNotes == true)
    }

    @Test func guidanceNeverSaysClaudeCode() {
        #expect(!Guidance.text.contains("Claude Code"))
        #expect(Guidance.text.hasPrefix("This project is shared with other sessions through Alloy."))
    }

    @Test @MainActor func answerPathNeverSendsSuggestions() async throws {
        let h = KHarness()
        let ws = workspace(AlloySettings(askBeforeSharedNotes: true), h)
        let s = await ws.newSession(name: "a")
        let line = try #require(Fixture.lines("permission-suggestion-mcp").first)
        // The recorded request really carries the settings-writing suggestion.
        #expect(String(decoding: line, as: UTF8.self).contains("\"destination\":\"localSettings\""))
        await h.transports[0].emit(fixture: [line])
        await waitUntil("awaiting") { s.status == .awaitingPermission }
        await ws.answerPermission(session: s.id, requestID: "74a1ab86-2a65-4d0c-8dc7-1180a9fda4f2", allow: true)
        await ws.settle()
        let sent = await h.transports[0].sentAfterInitialize
        guard case .allow(_, _, let permissions)? = sent.last else { Issue.record("no allow sent: \(sent)"); return }
        #expect(permissions == nil)
        #expect(!String(decoding: try #require(sent.last).line(), as: UTF8.self).contains("updatedPermissions"))
        await ws.stopAll()
    }

    private func wire(_ entries: [String]) throws -> String {
        let values = try entries.map { try JSONDecoder().decode(JSONValue.self, from: Data($0.utf8)) }
        return String(decoding: OutboundMessage.allow(requestID: "r", updatedInput: .object([:]),
                                                      updatedPermissions: values).line(), as: UTF8.self)
    }

    @Test func wireAllowListKeepsOnlySessionAndCliArg() throws {
        let local = #"{"type":"addRules","destination":"localSettings"}"#
        let session = #"{"type":"setMode","mode":"acceptEdits","destination":"session"}"#
        let mixed = try wire([local, session])
        #expect(!mixed.contains("localSettings") && mixed.contains("acceptEdits"))
        #expect(try wire([#"{"type":"setMode","destination":"cliArg"}"#]).contains("cliArg"))
        for dropped in [#"{"type":"addRules"}"#, #"{"type":"addRules","destination":"somethingNew"}"#,
                        #""session""#, #"7"#, #"{"type":"x","destination":5}"#, local] {
            #expect(!(try wire([dropped])).contains("updatedPermissions"), "kept \(dropped)")
        }
    }

    @Test @MainActor func restoredSessionResendsGuidanceWithSnapshotOff() async throws {
        let root = tempDir(), support = tempDir()
        let h1 = KHarness()
        let ws1 = Workspace(projectRoot: root, appSupport: support, settings: AlloySettings(),
                            locate: { _ in URL(fileURLWithPath: "/fake/claude") }, makeTransport: h1.factory, now: Date.init)
        _ = await ws1.newSession(name: "a")
        await h1.transports[0].emit(fixture: Fixture.lines("edit-turn"))
        await ws1.settle()
        await ws1.stopAll()
        let h2 = KHarness()
        let ws2 = Workspace(projectRoot: root, appSupport: support, settings: AlloySettings(),
                            locate: { _ in URL(fileURLWithPath: "/fake/claude") }, makeTransport: h2.factory, now: Date.init)
        await ws2.restore()
        let b = try #require(ws2.sessions.first)
        await ws2.send("again", to: b.id)
        await ws2.settle()
        let c = try #require(h2.configs.first)
        #expect(c.resume)
        let args = c.arguments()
        #expect(args.contains("--append-system-prompt"))
        let i = try #require(args.firstIndex(of: "--system-prompt-snapshot"))
        #expect(args[i + 1] == "off")
        await ws2.stopAll()
    }

    @Test @MainActor func serverDownLaunchesWithoutSharing() async throws {
        let h = KHarness()
        let ws = workspace(AlloySettings(), h)
        ws.failServerStartForTesting = true
        let s = await ws.newSession(name: "a")
        await ws.settle()
        #expect(ws.serverURL == nil)
        let c = try #require(h.configs.first)
        #expect(c.mcpConfigJSON == nil && c.appendSystemPrompt == nil && c.allowedTools.isEmpty)
        #expect(s.status == .idle)
        await ws.stopAll()
    }

    @Test @MainActor func listenerFailureStopsHandingOutTheConfig() async throws {
        let h = KHarness()
        let ws = workspace(AlloySettings(), h)
        _ = await ws.newSession(name: "a")
        await ws.settle()
        #expect(h.configs[0].mcpConfigJSON != nil && ws.serverURL != nil)
        // The listener dies after it was ready: its port could be taken by anything else on loopback.
        await ws.listenerFailed(CocoaError(.fileWriteUnknown))
        #expect(ws.serverURL == nil)
        #expect(ws.errors.contains { $0.contains("Shared notes stopped working") })
        let b = await ws.newSession(name: "b")
        await ws.settle()
        let c = try #require(h.configs.last)
        #expect(c.mcpConfigJSON == nil && c.appendSystemPrompt == nil && c.allowedTools.isEmpty)
        #expect(b.status == .idle)
        await ws.stopAll()
    }
}
