@testable import AlloyCore
import AlloyTestSupport
import Foundation
import Testing

private final class THarness: @unchecked Sendable {
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

@MainActor
private final class EndWorkshop: ThemeWorkshop {
    var slotCatalog: [ThemeSlotInfo] = []
    var library = ThemeLibrary(builtIns: BuiltInThemes.all, user: [])
    var shownTheme: ResolvedTheme?
    var ended: [UUID] = []
    func preview(_ draft: ThemeFile, resolved: ResolvedTheme, session: UUID) {}
    func didSave(_ saved: SavedTheme, file: ThemeFile, session: UUID) async {}
    func themeSessionEnded(_ session: UUID) { ended.append(session) }
}

private func toolNames(_ url: URL, token: String) async throws -> [String] {
    var req = URLRequest(url: url)
    req.httpMethod = "POST"
    req.httpBody = Data(#"{"jsonrpc":"2.0","id":1,"method":"tools/list"}"#.utf8)
    req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
    let (data, _) = try await URLSession(configuration: .ephemeral).data(for: req)
    let json = try JSONDecoder().decode(JSONValue.self, from: data)
    return json["result"]?["tools"]?.arrayValue?.compactMap { $0["name"]?.stringValue } ?? []
}

private func token(_ c: LaunchConfiguration) throws -> String {
    let json = try #require(c.mcpConfigJSON)
    return String(try #require(json.components(separatedBy: "Bearer ").dropFirst().first?.prefix(while: { $0 != "\"" })))
}

private func userTexts(_ t: ScriptedTransport) async -> [String] {
    await t.sentAfterInitialize.compactMap { m -> String? in
        guard case .user(let c, _, _) = m else { return nil }
        return c.compactMap { if case .text(let s) = $0 { s } else { nil } }.joined()
    }
}

@Suite final class ThemeSessionTests {
    private var dirs: [URL] = []
    deinit { dirs.forEach { try? FileManager.default.removeItem(at: $0) } }

    private func tempDir() -> URL {
        let u = FileManager.default.temporaryDirectory.appendingPathComponent("alloy-ts-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        let r = u.resolvingSymlinksInPath()
        dirs.append(r)
        return r
    }

    @MainActor
    private func workspace(_ settings: AlloySettings, _ h: THarness, root: URL? = nil, support: URL? = nil) -> Workspace {
        Workspace(projectRoot: root ?? tempDir(), appSupport: support ?? tempDir(), settings: settings,
                  locate: { _ in URL(fileURLWithPath: "/fake/claude") }, makeTransport: h.factory, now: Date.init)
    }

    private let result = InboundMessage.result(TurnResult(subtype: "success", isError: false, costUSD: 0, inputTokens: 0,
                                                          outputTokens: 0, sessionID: "s", terminalReason: nil))

    @Test @MainActor func themeCommandStartsANamedThemeSession() async throws {
        let h = THarness()
        let ws = workspace(AlloySettings(), h)
        let a = await ws.newSession(name: "A")
        await ws.send("/theme warm, low contrast", to: a.id)
        await ws.settle()
        #expect(ws.sessions.count == 2)
        let t = try #require(ws.sessions.last)
        #expect(t.name == "Theme: warm, low contrast" && t.purpose == .theme)
        #expect(ws.selectedSessionID == t.id)
        #expect(await userTexts(h.transports[1]) == ["warm, low contrast"])
        #expect(!a.transcript.blocks.contains { if case .user = $0 { true } else { false } })
        await ws.stopAll()
    }

    @Test @MainActor func aSlashInTheDescriptionIsSentVerbatim() async throws {
        let h = THarness()
        let ws = workspace(AlloySettings(), h)
        let a = await ws.newSession(name: "A")
        await ws.send("/theme /help", to: a.id)
        await ws.settle()
        #expect(ws.sessions.filter { $0.purpose == .theme }.count == 1)
        let t = try #require(ws.sessions.last)
        #expect(await userTexts(h.transports[1]) == ["/help"])
        #expect(!t.transcript.blocks.contains { if case .notice(_, .commandOutput, _) = $0 { true } else { false } })
        await ws.stopAll()
    }

    @Test @MainActor func bareThemeSendsTheOpeningLine() async throws {
        let h = THarness()
        let ws = workspace(AlloySettings(), h)
        let t = await ws.newThemeSession(description: nil)
        await ws.settle()
        #expect(t.name == "Theme: new")
        #expect(await userTexts(h.transports[0]) == ["Help me make an Alloy theme."])
        let long = await ws.newThemeSession(description: String(repeating: "x", count: 60))
        #expect(long.name == "Theme: " + String(repeating: "x", count: 40) + "\u{2026}")
        await ws.stopAll()
    }

    @Test @MainActor func themeLaunchHasThemeGuidanceToolsAndScope() async throws {
        let h = THarness()
        let ws = workspace(AlloySettings(), h)
        _ = await ws.newThemeSession(description: "x")
        await ws.settle()
        let c = try #require(h.configs.first)
        #expect(c.appendSystemPrompt == Guidance.text(shareKnowledge: true, shareAcrossProjects: true) + "\n\n" + ThemeGuidance.text)
        #expect(c.allowedTools == Guidance.alloyToolNames + Guidance.themeToolNames)
        #expect(c.extraSettingsJSON != nil)
        let url = try #require(ws.serverURL), tok = try token(c)
        let names = try await toolNames(url, token: tok)
        #expect(names.contains("theme_save"))
        #expect(names.contains("notes_read"))
        await ws.stopAll()
    }

    @Test @MainActor func codingSessionNeverSeesThemeTools() async throws {
        let h = THarness()
        let ws = workspace(AlloySettings(), h)
        _ = await ws.newSession(name: "a")
        await ws.settle()
        let c = try #require(h.configs.first)
        #expect(Set(c.allowedTools).isDisjoint(with: Guidance.themeToolNames))
        #expect(c.appendSystemPrompt?.contains(ThemeGuidance.text) == false)
        let url = try #require(ws.serverURL), tok = try token(c)
        let names = try await toolNames(url, token: tok)
        #expect(!names.isEmpty && !names.contains { $0.hasPrefix("theme_") })
        await ws.stopAll()
    }

    @Test @MainActor func themeToolsWorkWithSharingOff() async throws {
        let h = THarness()
        let ws = workspace(AlloySettings(shareKnowledge: false), h)
        _ = await ws.newThemeSession(description: "x")
        await ws.settle()
        let c = try #require(h.configs.first)
        #expect(c.mcpConfigJSON != nil)
        #expect(c.extraSettingsJSON == nil)
        #expect(c.appendSystemPrompt == ThemeGuidance.text)
        #expect(c.allowedTools == Guidance.themeToolNames)
        let url = try #require(ws.serverURL), tok = try token(c)
        let names = try await toolNames(url, token: tok)
        #expect(names.contains("theme_save") && !names.contains("notes_read"))
        await ws.stopAll()
    }

    @Test @MainActor func askBeforeApprovesNothing() async throws {
        let h = THarness()
        var s = AlloySettings(); s.askBeforeSharedNotes = true
        let ws = workspace(s, h)
        _ = await ws.newThemeSession(description: "x")
        await ws.settle()
        #expect(h.configs.first?.allowedTools == [])
        await ws.stopAll()
    }

    @Test @MainActor func themePurposeSurvivesRestoreRelaunchAndFork() async throws {
        let root = tempDir(), support = tempDir()
        let h1 = THarness()
        let ws1 = workspace(AlloySettings(), h1, root: root, support: support)
        let t = await ws1.newThemeSession(description: "x")
        await h1.transports[0].emit(result)
        await waitUntil("idle with conversation") { t.status == .idle && t.hasConversation }
        // Relaunch after a settings change.
        ws1.relaunchWhenIdle(t.id)
        await waitUntil("relaunched") { h1.configs.count == 2 }
        await ws1.settle()
        #expect(h1.configs[1].appendSystemPrompt?.contains(ThemeGuidance.text) == true)
        #expect(h1.configs[1].allowedTools.contains("mcp__alloy__theme_save"))
        await h1.transports[1].emit(result)
        await waitUntil("idle again") { t.status == .idle }
        // Fork.
        let fork = try #require(await ws1.fork(t.id, name: nil))
        await ws1.settle()
        #expect(fork.purpose == .theme)
        #expect(h1.configs[2].appendSystemPrompt?.contains(ThemeGuidance.text) == true)
        await ws1.stopAll()
        // Restore and wake.
        let h2 = THarness()
        let ws2 = workspace(AlloySettings(), h2, root: root, support: support)
        await ws2.restore()
        let restored = try #require(ws2.sessions.first { $0.id == t.id })
        #expect(restored.purpose == .theme)
        await ws2.wake(t.id)
        #expect(h2.configs.first?.appendSystemPrompt?.contains(ThemeGuidance.text) == true)
        #expect(h2.configs.first?.allowedTools.contains("mcp__alloy__theme_save") == true)
        await ws2.stopAll()
    }

    @Test @MainActor func sessionEndTellsTheWorkshop() async throws {
        let h = THarness()
        let ws = workspace(AlloySettings(), h)
        let shop = EndWorkshop()
        ws.themeWorkshop = shop
        let t1 = await ws.newThemeSession(description: "one")
        let coding = await ws.newSession(name: "code")
        await ws.settle()
        await ws.stop(coding.id)
        #expect(shop.ended.isEmpty)
        // A settings relaunch is not an end.
        await h.transports[0].emit(result)
        await waitUntil("idle") { t1.status == .idle }
        ws.relaunchWhenIdle(t1.id)
        await waitUntil("relaunched") { h.configs.count == 3 }
        await ws.settle()
        #expect(shop.ended.isEmpty)
        await ws.stop(t1.id)
        #expect(shop.ended == [t1.id])
        let t2 = await ws.newThemeSession(description: "two")
        await ws.settle()
        await h.transports[h.transports.count - 1].exit(status: 1, stderr: "boom")
        await waitUntil("exited") { shop.ended.count == 2 }
        #expect(shop.ended == [t1.id, t2.id])
        await ws.stopAll()
    }

    @Test func themeGuidanceIsShortAndUnbranded() {
        #expect(ThemeGuidance.text.split(whereSeparator: \.isWhitespace).count < 200)
        #expect(!ThemeGuidance.text.contains("Claude Code"))
    }
}
