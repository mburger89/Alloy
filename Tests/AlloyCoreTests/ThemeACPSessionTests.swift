@testable import AlloyCore
import AlloyTestSupport
import Foundation
import Testing

private final class TRig: @unchecked Sendable {
    private let lock = NSLock()
    private var _configs: [ACPLaunchConfiguration] = []
    var configs: [ACPLaunchConfiguration] { lock.withLock { _configs } }
    var factory: ACPTransportFactory {
        { [self] c in lock.withLock { _configs.append(c) }; return ScriptedTransport() }
    }
}

@MainActor
private final class TWorkshop: ThemeWorkshop {
    var slotCatalog: [ThemeSlotInfo] = []
    var library = ThemeLibrary(builtIns: BuiltInThemes.all, user: [])
    var themesFolderPath = "/x/Alloy/Themes"
    var shownTheme: ResolvedTheme?
    func preview(_ draft: ThemeFile, resolved: ResolvedTheme, session: UUID) {}
    func didSave(_ saved: SavedTheme, file: ThemeFile, session: UUID) async {}
    func themeSessionEnded(_ session: UUID) {}
}

private let opencode = AgentDefinition(id: "opencode", name: "OpenCode", command: "/abs/opencode", args: ["acp"])

/// Theme sessions on ACP agents. Every workspace here lives in a temporary directory.
@MainActor @Suite struct ThemeACPSessionTests {
    private let base: URL
    private let shop = TWorkshop()

    init() {
        base = FileManager.default.temporaryDirectory.appendingPathComponent("alloy-tacp-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: base.appendingPathComponent("p"), withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: base.appendingPathComponent("s"), withIntermediateDirectories: true)
    }

    private func workspace(_ rig: TRig, settings: AlloySettings = AlloySettings()) -> Workspace {
        let ws = Workspace(projectRoot: base.appendingPathComponent("p").resolvingSymlinksInPath(),
                           appSupport: base.appendingPathComponent("s"), settings: settings,
                           locate: { _ in URL(fileURLWithPath: "/fake/claude") },
                           makeTransport: { _ in ScriptedTransport() }, makeACPTransport: rig.factory,
                           agentDefinitions: { [opencode] }, agentSecrets: InMemorySecretStore(),
                           agentDetector: AgentDetector(resolve: { _ in [:] }, isExecutable: { _ in true }, home: "/nohome",
                                                        helpRunner: { _ in nil }),
                           now: Date.init, home: base.appendingPathComponent("home"),
                           changes: { _ in ScriptedChangeSource() })
        ws.themeWorkshop = shop
        return ws
    }

    private func finish(_ ws: Workspace) async {
        await ws.stopAll()
        try? FileManager.default.removeItem(at: base)
    }

    @Test func slashThemeInACPSessionUsesThatAgent() async throws {
        let rig = TRig()
        let ws = workspace(rig)
        let a = await ws.newSession(name: "A", backend: .acp(agentID: "opencode"))
        await ws.send("/theme dusk", to: a.id)
        await ws.settle()
        let theme = try #require(ws.sessions.first { $0.purpose == .theme })
        #expect(theme.backend == .acp(agentID: "opencode"))
        #expect(!a.transcript.blocks.contains { if case .notice(_, _, let text) = $0 { text.contains("not available") } else { false } })
        await finish(ws)
    }

    @Test func acpThemeLaunchGetsThemeGuidance() async throws {
        let rig = TRig()
        let ws = workspace(rig)
        _ = await ws.newThemeSession(description: "x", backend: .acp(agentID: "opencode"))
        await ws.settle()
        let c = try #require(rig.configs.first)
        #expect(c.mcp != nil)
        #expect(c.systemPrompt?.contains(ThemeGuidance.acpText) == true)
        #expect(c.autoAllowThemeTools)
        #expect(c.promptWithoutTools == ThemeGuidance.fileModeText(themesFolder: "/x/Alloy/Themes"))
        #expect(c.toolsUnavailableNotice == "OpenCode can't use Alloy's theme tools, so it will write the theme file into your "
                + "themes folder instead; Alloy picks it up live.")
        await finish(ws)
    }

    @Test func acpThemeAskBeforeSharedNotes() async throws {
        var settings = AlloySettings()
        settings.askBeforeSharedNotes = true
        let rig = TRig()
        let ws = workspace(rig, settings: settings)
        _ = await ws.newThemeSession(description: "x", backend: .acp(agentID: "opencode"))
        await ws.settle()
        let c = try #require(rig.configs.first)
        #expect(!c.autoAllowThemeTools)
        #expect(!c.autoAllowAlloyTools)
        await finish(ws)
    }

    @Test func acpThemeRelaunchKeepsTools() async throws {
        let rig = TRig()
        let ws = workspace(rig)
        let t = await ws.newThemeSession(description: "x", backend: .acp(agentID: "opencode"))
        await ws.settle()
        await ws.restartACP(t.id)
        await ws.settle()
        #expect(rig.configs.count == 2)
        let c = rig.configs[1]
        #expect(c.mcp != nil)
        #expect(c.systemPrompt?.contains(ThemeGuidance.acpText) == true)
        #expect(c.autoAllowThemeTools && c.promptWithoutTools != nil)
        await finish(ws)
    }

    @Test func themeToolsFallbackFieldsWithoutAServer() async throws {
        var settings = AlloySettings()
        settings.shareKnowledge = false
        let rig = TRig()
        let ws = workspace(rig, settings: settings)
        _ = await ws.newThemeSession(description: "x", backend: .acp(agentID: "opencode"))
        await ws.settle()
        let c = try #require(rig.configs.first)
        #expect(c.mcp != nil, "the theme scope alone brings the server")
        #expect(c.systemPrompt == ThemeGuidance.acpText)
        await finish(ws)
    }

    @Test func newThemeSessionDefaultsToDefaultAgent() async throws {
        var settings = AlloySettings()
        settings.defaultAgentID = "opencode"
        let rig = TRig()
        let ws = workspace(rig, settings: settings)
        let t = await ws.newThemeSession(description: nil)
        #expect(t.backend == .acp(agentID: "opencode"))
        #expect(ws.defaultAgentName == "OpenCode")
        await finish(ws)
    }
}
