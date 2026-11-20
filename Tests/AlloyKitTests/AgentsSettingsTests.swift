@testable import AlloyCore
@testable import AlloyKit
import AlloyTestSupport
import Foundation
import MetalUI
import MetalUITesting
import Testing

/// A store that cannot hold secrets (no Keychain).
private struct UnavailableStore: AgentSecretStore {
    var isAvailable: Bool { false }
    func set(_ value: String, agent: String, variable: String) throws { throw SecretStoreError(status: -1) }
    func get(agent: String, variable: String) throws -> String? { nil }
    func delete(agent: String, variable: String) throws {}
    func deleteAll(agent: String) throws {}
}

private final class ResolveLog: @unchecked Sendable {
    private let lock = NSLock()
    private var calls = 0
    var count: Int { lock.withLock { calls } }
    func bump() { lock.withLock { calls += 1 } }
}

@MainActor
@Suite struct AgentsSettingsTests {
    private func open(_ rig: Rig) async throws -> (main: TestWindow, settings: TestWindow) {
        let main = try alloyWindow(rig.workspace)
        let settings = try main.openSettingsFromMenu()
        try await settings.runUntil { (try? settings.element(identifier: "settings-agents-section")) != nil }
        return (main, settings)
    }

    private func exists(_ w: TestWindow, _ id: String) -> Bool { (try? w.element(identifier: id)) != nil }
    private func text(_ w: TestWindow, _ id: String) throws -> String {
        let e = try w.element(identifier: id)
        return e.value ?? e.label ?? ""
    }
    private func settle(_ w: TestWindow) { for _ in 0..<4 { w.tick() } }
    private func settleAsync(_ w: TestWindow, _ cond: () -> Bool) async throws {
        for _ in 0..<200 where !cond() { w.tick(); try await Task.sleep(for: .milliseconds(10)) }
    }

    private static func detector(missing: Set<String> = [], log: ResolveLog? = nil) -> AgentDetector {
        AgentDetector(resolve: { names in
            log?.bump()
            return Dictionary(uniqueKeysWithValues: names.filter { !missing.contains($0) }.map { ($0, "/fake/" + $0) })
        }, isExecutable: { $0.hasPrefix("/fake/") }, home: "/nohome", helpRunner: { _ in nil })
    }

    @Test func listsPresetsGreyedWithInstallCommand() async throws {
        let rig = Rig(detector: Self.detector(missing: ["codex-acp"]))
        let (_, settings) = try await open(rig)
        _ = try settings.element(identifier: "agents-list")
        for def in AgentPresets.all { #expect(exists(settings, "agents-row-\(def.id)")) }
        try await settleAsync(settings) { rig.workspace.detectedAgents.count == AgentPresets.all.count }
        settle(settings)
        #expect(try text(settings, "agents-status-codex") == "Not installed")
        #expect(try text(settings, "agents-status-opencode") == "Installed")
        #expect(try text(settings, "agents-install-codex") == "npm install -g @agentclientprotocol/codex-acp")
        #expect(exists(settings, "agents-copy-codex"))
        #expect(!exists(settings, "agents-install-opencode"))
        // Presets are neither editable nor removable.
        #expect(!exists(settings, "agents-remove-codex"))
    }

    @Test func detectButtonResetsLoginCacheAndRefreshes() async throws {
        let log = ResolveLog()
        let rig = Rig(detector: Self.detector(log: log))
        let (_, settings) = try await open(rig)
        try await settleAsync(settings) { rig.workspace.detectedAgents.count == AgentPresets.all.count }
        let first = log.count
        #expect(first >= 1)
        rig.workspace.cachedLoginPATH = .some("/stale")
        try settings.click(settings.element(identifier: "agents-detect"))
        try await settleAsync(settings) { log.count > first }
        #expect(log.count > first)
        #expect(rig.workspace.cachedLoginPATH == nil)
        // Not forced: answered agents are not looked up again.
        let after = log.count
        await rig.workspace.detectAgents()
        #expect(log.count == after)
    }

    @Test func forceDetectFindsACommandInstalledMeanwhile() async throws {
        final class Flag: @unchecked Sendable { let l = NSLock(); var on = false }
        let flag = Flag()
        let detector = AgentDetector(resolve: { names in
            flag.l.withLock { flag.on } ? Dictionary(uniqueKeysWithValues: names.map { ($0, "/fake/" + $0) }) : [:]
        }, isExecutable: { $0.hasPrefix("/fake/") }, home: "/nohome", helpRunner: { _ in nil })
        let rig = Rig(detector: detector)
        await rig.workspace.detectAgents()
        #expect(rig.workspace.installedAgents.isEmpty)
        flag.l.withLock { flag.on = true }
        await rig.workspace.detectAgents()
        #expect(rig.workspace.installedAgents.isEmpty)
        await rig.workspace.detectAgents(force: true)
        #expect(rig.workspace.installedAgents.count == AgentPresets.all.count)
    }

    @Test func addAgentPersistsNamesNotValues() async throws {
        let rig = Rig()
        let (_, settings) = try await open(rig)
        try settings.click(settings.element(identifier: "agents-add"))
        try await settings.runUntil { self.exists(settings, "agents-form-name") }
        try settings.typeText("My Agent", into: settings.element(identifier: "agents-form-name"))
        try settings.typeText("my-agent", into: settings.element(identifier: "agents-form-command"))
        try settings.typeText("--acp --fast", into: settings.element(identifier: "agents-form-args"))
        try settings.typeText("MODE=fast", into: settings.element(identifier: "agents-form-env"))
        try settings.click(settings.element(identifier: "agents-form-save"))
        settle(settings)
        let def = try #require(rig.workspace.settings.agents.first)
        #expect(def.id == "my-agent" && def.name == "My Agent" && def.command == "my-agent")
        #expect(def.args == ["--acp", "--fast"] && def.env == [EnvVar(name: "MODE", value: "fast")])
        #expect(!def.isPreset)
        #expect(exists(settings, "agents-row-my-agent"))
        #expect(!exists(settings, "agents-form"))
        let reloaded = AlloySettings.load(appSupport: rig.workspace.appSupport)
        #expect(reloaded.agents == [def])
    }

    @Test func secretNamesAreSavedButValuesNeverReachTheSettingsFile() throws {
        let rig = Rig()
        let def = AgentDefinition(id: "mine", name: "Mine", command: "mine", secretNames: ["API_KEY"])
        try rig.workspace.saveAgent(def)
        try rig.secrets.set("hunter2-value", agent: "mine", variable: "API_KEY")
        let file = try String(contentsOf: rig.workspace.appSupport.appendingPathComponent("Alloy/settings.json"), encoding: .utf8)
        #expect(file.contains("API_KEY"))
        #expect(!file.contains("hunter2-value"))
        #expect(rig.workspace.storedAgentSecrets().map(\.name) == ["API_KEY"])
    }

    @Test func secretLookingEnvShowsExactRefusal() async throws {
        let rig = Rig()
        let (_, settings) = try await open(rig)
        try settings.click(settings.element(identifier: "agents-add"))
        try await settings.runUntil { self.exists(settings, "agents-form-name") }
        try settings.typeText("Bad", into: settings.element(identifier: "agents-form-name"))
        try settings.typeText("bad", into: settings.element(identifier: "agents-form-command"))
        try settings.typeText("OPENAI_API_KEY=abc", into: settings.element(identifier: "agents-form-env"))
        settle(settings)
        #expect(try text(settings, "agents-form-env-refusal") == "Add this under Secrets; Alloy keeps it in your Keychain.")
        try settings.click(settings.element(identifier: "agents-form-save"))
        settle(settings)
        #expect(rig.workspace.settings.agents.isEmpty)
        // The core refuses too.
        #expect(throws: AgentDefinitionError.self) {
            try rig.workspace.saveAgent(AgentDefinition(id: "x", name: "X", command: "x", env: [EnvVar(name: "MY_TOKEN", value: "v")]))
        }
    }

    @Test func removeAgentDeletesKeychainItems() async throws {
        let rig = Rig()
        try rig.workspace.saveAgent(AgentDefinition(id: "mine", name: "Mine", command: "mine", secretNames: ["TOK"]))
        try rig.secrets.set("v", agent: "mine", variable: "TOK")
        try rig.secrets.set("w", agent: "other", variable: "TOK")
        try rig.workspace.setDefaultAgent("mine")
        let (_, settings) = try await open(rig)
        try settings.click(settings.element(identifier: "agents-remove-mine"))
        settle(settings)
        #expect(rig.workspace.settings.agents.isEmpty)
        #expect(try rig.secrets.get(agent: "mine", variable: "TOK") == nil)
        #expect(try rig.secrets.get(agent: "other", variable: "TOK") == "w")
        #expect(rig.workspace.settings.defaultAgentID == nil)
        #expect(!exists(settings, "agents-row-mine"))
    }

    @Test func secretsListShowsNamesWithRemoveAndAnEnabledAddRow() async throws {
        let rig = Rig()
        try rig.workspace.saveAgent(AgentDefinition(id: "mine", name: "Mine", command: "mine", secretNames: ["TOK"]))
        try rig.secrets.set("never-shown", agent: "mine", variable: "TOK")
        let (_, settings) = try await open(rig)
        _ = try settings.element(identifier: "agents-secrets")
        let shown = try text(settings, "agents-secret-mine-TOK")
        #expect(shown.contains("TOK") && !shown.contains("never-shown"))
        #expect(try settings.element(identifier: "agents-secret-add").isEnabled)
        try settings.click(settings.element(identifier: "agents-secret-remove-mine-TOK"))
        settle(settings)
        #expect(try rig.secrets.get(agent: "mine", variable: "TOK") == nil)
        #expect(rig.workspace.settings.agents.first?.secretNames == [])
        #expect(!exists(settings, "agents-secret-mine-TOK"))
    }

    @Test func secretsListHiddenWhenStoreUnavailable() async throws {
        let rig = Rig(secrets: UnavailableStore())
        let (_, settings) = try await open(rig)
        #expect(!exists(settings, "agents-secrets"))
        #expect(!exists(settings, "agents-secret-add"))
        #expect(exists(settings, "agents-list"))
    }

    @Test func defaultAgentChoiceDrivesNewSession() async throws {
        let rig = Rig()
        #expect(rig.workspace.defaultBackend == .claude)
        let (_, settings) = try await open(rig)
        try await settleAsync(settings) { rig.workspace.installedAgents.count == AgentPresets.all.count }
        settle(settings)
        _ = try settings.element(identifier: "agents-default")
        try rig.workspace.setDefaultAgent("codex")
        #expect(rig.workspace.defaultBackend == .acp(agentID: "codex"))
        #expect(AlloySettings.load(appSupport: rig.workspace.appSupport).defaultAgentID == "codex")
        try rig.workspace.setDefaultAgent(nil)
        #expect(rig.workspace.defaultBackend == .claude)
    }

    @Test func customAgentIsADefinitionAndCannotShadowAPreset() throws {
        let rig = Rig()
        try rig.workspace.saveAgent(AgentDefinition(id: "mine", name: "Mine", command: "mine"))
        #expect(rig.workspace.agentDefinitions().contains { $0.id == "mine" })
        #expect(throws: AgentIDTakenError.self) {
            try rig.workspace.saveAgent(AgentDefinition(id: "codex", name: "Mine", command: "mine"))
        }
    }

    @Test func sectionSitsAfterLanguageServersAndBeforeTerminal() async throws {
        let rig = Rig()
        let (_, settings) = try await open(rig)
        let ids = ["settings-lsp-section", "settings-agents-section", "settings-terminal-heading"]
        if let ys = try? ids.map({ try settings.element(identifier: $0).frame.minY }) {
            #expect(ys == ys.sorted(), "\(ys)")
        }
    }

    // MARK: Secret entry

    private static let secretValue = "sk-test-never-leak-0123456789"

    private func secretRig() throws -> Rig {
        let rig = Rig()
        try rig.workspace.saveAgent(AgentDefinition(id: "mine", name: "Mine", command: "mine"))
        try rig.workspace.setDefaultAgent("mine")
        return rig
    }

    private func openForm(_ settings: TestWindow) async throws {
        try settings.click(settings.element(identifier: "agents-secret-add"))
        try await settings.runUntil { self.exists(settings, "agents-secret-form") }
    }

    private func fillSecret(_ settings: TestWindow, name: String, value: String) throws {
        try settings.typeText(name, into: settings.element(identifier: "agents-secret-name"))
        try settings.typeText(value, into: settings.element(identifier: "agents-secret-value"))
        settle(settings)
    }

    /// Every string the window publishes: labels, values, hints and identifiers.
    private func treeDump(_ w: TestWindow) throws -> String {
        try w.elements { _ in true }.map { [$0.label, $0.value, $0.hint, $0.identifier].compactMap { $0 }.joined(separator: "|") }
            .joined(separator: "\n")
    }

    @Test func savingASecretStoresItUnderTheAgentAndClearsTheField() async throws {
        let rig = try secretRig()
        let (_, settings) = try await open(rig)
        try await openForm(settings)
        #expect(try settings.element(identifier: "agents-secret-value").role == .secureTextField)
        try fillSecret(settings, name: "api_key", value: Self.secretValue)
        #expect(try settings.element(identifier: "agents-secret-name").value == "API_KEY")
        #expect(try settings.element(identifier: "agents-secret-save").isEnabled)
        try settings.click(settings.element(identifier: "agents-secret-save"))
        settle(settings)
        #expect(try rig.secrets.get(agent: "mine", variable: "API_KEY") == Self.secretValue)
        #expect(!exists(settings, "agents-secret-form"))
        #expect(exists(settings, "agents-secret-mine-API_KEY"))
        #expect(rig.workspace.settings.agents.first?.secretNames == [])
        #expect(try text(settings, "agents-secret-notice") == "Saved API_KEY.")
        // Reopening shows an empty value field.
        try await openForm(settings)
        #expect((try settings.element(identifier: "agents-secret-value").value ?? "").isEmpty)
        #expect(!(try treeDump(settings)).contains(Self.secretValue))
    }

    @Test func savingAnExistingNameReplacesItWithoutConfirmation() async throws {
        let rig = try secretRig()
        try rig.secrets.set("old", agent: "mine", variable: "API_KEY")
        let (_, settings) = try await open(rig)
        try await openForm(settings)
        try fillSecret(settings, name: "API_KEY", value: "new-value")
        try settings.click(settings.element(identifier: "agents-secret-save"))
        settle(settings)
        #expect(try rig.secrets.get(agent: "mine", variable: "API_KEY") == "new-value")
        #expect(try text(settings, "agents-secret-notice") == "Replaced API_KEY.")
    }

    @Test func submittingTheValueFieldSaves() async throws {
        let rig = try secretRig()
        let (_, settings) = try await open(rig)
        try await openForm(settings)
        try fillSecret(settings, name: "TOKEN_X", value: Self.secretValue)
        settings.typeKey(.return)
        settle(settings)
        #expect(try rig.secrets.get(agent: "mine", variable: "TOKEN_X") == Self.secretValue)
        #expect(!exists(settings, "agents-secret-form"))
    }

    @Test func cancelStoresNothingAndClears() async throws {
        let rig = try secretRig()
        let (_, settings) = try await open(rig)
        try await openForm(settings)
        try fillSecret(settings, name: "API_KEY", value: Self.secretValue)
        try settings.click(settings.element(identifier: "agents-secret-cancel"))
        settle(settings)
        #expect(!exists(settings, "agents-secret-form"))
        #expect(try rig.secrets.names(agent: "mine").isEmpty)
        try await openForm(settings)
        #expect((try settings.element(identifier: "agents-secret-value").value ?? "").isEmpty)
        #expect(!(try treeDump(settings)).contains(Self.secretValue))
    }

    @Test func anInvalidNameIsRefusedAndAnEmptyValueDisablesSave() async throws {
        let rig = try secretRig()
        let (_, settings) = try await open(rig)
        try await openForm(settings)
        // No value yet: Save is disabled even with a good name.
        try settings.typeText("GOOD_NAME", into: settings.element(identifier: "agents-secret-name"))
        settle(settings)
        #expect(!(try settings.element(identifier: "agents-secret-save").isEnabled))
        try settings.typeText("v", into: settings.element(identifier: "agents-secret-value"))
        settle(settings)
        #expect(try settings.element(identifier: "agents-secret-save").isEnabled)
        // A bad name shows the message and disables Save.
        try settings.typeText("-bad name", into: settings.element(identifier: "agents-secret-name"))
        settle(settings)
        #expect(exists(settings, "agents-secret-name-refusal"))
        #expect(!(try settings.element(identifier: "agents-secret-save").isEnabled))
        try settings.click(settings.element(identifier: "agents-secret-value"))
        settings.typeKey(.return)
        settle(settings)
        #expect(try rig.secrets.names(agent: "mine").isEmpty)
        #expect(AgentsSettingsSection.isValidSecretName("_A1"))
        #expect(!AgentsSettingsSection.isValidSecretName("1A"))
        #expect(!AgentsSettingsSection.isValidSecretName("A-B"))
        #expect(!AgentsSettingsSection.isValidSecretName(""))
    }

    @Test func theValueNeverReachesSettingsFileOrTheTree() async throws {
        let rig = try secretRig()
        let (main, settings) = try await open(rig)
        try await openForm(settings)
        try fillSecret(settings, name: "API_KEY", value: Self.secretValue)
        // While typing: the field shows bullets only.
        #expect(!(try treeDump(settings)).contains(Self.secretValue))
        try settings.click(settings.element(identifier: "agents-secret-save"))
        settle(settings)
        let file = try String(contentsOf: rig.workspace.appSupport.appendingPathComponent("Alloy/settings.json"), encoding: .utf8)
        #expect(!file.contains(Self.secretValue))
        #expect(!(try treeDump(settings)).contains(Self.secretValue))
        #expect(!(try treeDump(main)).contains(Self.secretValue))
    }

    @Test func addIsHiddenWhenTheStoreIsUnavailable() async throws {
        let (_, settings) = try await open(Rig(secrets: UnavailableStore()))
        #expect(!exists(settings, "agents-secret-add") && !exists(settings, "agents-secret-form"))
    }

    @Test func aSecretSavedForAPresetReachesOnlyThatPresetsEnvironment() async throws {
        let rig = Rig()
        let (_, settings) = try await open(rig)
        try await openForm(settings)
        // The form defaults to the first agent (Codex) when no default agent is set.
        #expect(exists(settings, "agents-secret-agent"))
        try fillSecret(settings, name: "OPENAI_API_KEY", value: Self.secretValue)
        try settings.click(settings.element(identifier: "agents-secret-save"))
        settle(settings)
        let codex = try #require(AgentPresets.preset(id: "codex"))
        let gemini = try #require(AgentPresets.preset(id: "gemini"))
        #expect(codex.resolveEnvironment(store: rig.secrets).env["OPENAI_API_KEY"] == Self.secretValue)
        #expect(gemini.resolveEnvironment(store: rig.secrets).env["OPENAI_API_KEY"] == nil)
        #expect(try rig.secrets.names(agent: "gemini").isEmpty)
        #expect(rig.workspace.settings.agents.isEmpty)
    }

    @Test func idleSettingsPageWithTheSecretFormOpenCostsZero() async throws {
        let rig = try secretRig()
        _ = await rig.workspace.newSession(name: "A")
        let main = try alloyWindow(rig.workspace)
        let before = await idleFrame(main)
        let settings = try main.openSettingsFromMenu()
        try await settings.runUntil { self.exists(settings, "settings-agents-section") }
        try await openForm(settings)
        try fillSecret(settings, name: "API_KEY", value: Self.secretValue)
        await rig.workspace.detectAgents()
        let open = await idleFrame(main)
        #expect(open == before, "main idle frame with the secret form open \(open), before \(before)")
        let own = await idleFrame(settings)
        #expect(own == 0, "idle settings frame \(own)")
    }

    // MARK: Frame guards

    private func idleFrame(_ window: TestWindow) async -> Int {
        var last = -1
        for _ in 0..<40 {
            window.resetFrameWork()
            window.tick()
            await Task.yield()
            let now = window.frameWork.last?.elementRequests ?? 0
            if now == last { return now }
            last = now
        }
        return last
    }

    @Test func closedSettingsAgentsSectionCostsZero() async throws {
        let rig = Rig()
        _ = await rig.workspace.newSession(name: "A")
        let main = try alloyWindow(rig.workspace)
        let before = await idleFrame(main)
        let settings = try main.openSettingsFromMenu()
        try await settings.runUntil { self.exists(settings, "settings-agents-section") }
        await rig.workspace.detectAgents()
        let open = await idleFrame(main)
        #expect(open == before, "main idle frame with Agents open \(open), before \(before)")
    }

    @Test func settingsOpenDoesNotRaiseChatGuard() async throws {
        let rig = Rig()
        _ = await rig.workspace.newSession(name: "A")
        let main = try alloyWindow(rig.workspace)
        let before = await idleFrame(main)
        let settings = try main.openSettingsFromMenu()
        try await settings.runUntil { self.exists(settings, "settings-agents-section") }
        try rig.workspace.saveAgent(AgentDefinition(id: "mine", name: "Mine", command: "mine"))
        settle(settings)
        let after = await idleFrame(main)
        #expect(after <= before, "chat idle frame \(after) vs \(before)")
        #expect(after <= ViewRerunTests.steadyFrameRequests)
    }
}
