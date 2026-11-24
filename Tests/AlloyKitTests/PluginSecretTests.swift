import AlloyCore
@testable import AlloyKit
import AlloyPlugins
import AlloyRPC
import AlloyTestSupport
import Foundation
import MetalUI
import MetalUITesting
import Testing

@MainActor
private func waitFor(_ timeout: Duration = .seconds(10), _ condition: @MainActor () async -> Bool) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while clock.now < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(20))
    }
    return await condition()
}

@MainActor
@Suite(.serialized) struct PluginSecretTests {
    private static let id = "dev.test.secret"
    private static let value = "abc123"
    private static let contributes: JSONValue = .object([
        "settings": .array([.object(["key": .string("token"), "title": .string("API token"), "type": .string("secret"),
                                     "env": .string("TODO_TOKEN")])]),
    ])

    private func rig(secrets: any AgentSecretStore = InMemorySecretStore(), script: JSONValue = .object([:])) throws -> (PluginRig, URL) {
        let p = PluginRig(pathDirs: [fakePluginDirectory, "/usr/bin", "/bin"], secrets: secrets)
        let folder = try p.fake(Self.id, script: script, contributes: Self.contributes)
        return (p, folder)
    }

    private func settingsText(_ p: PluginRig) -> String {
        let url = p.rig.workspace.appSupport.appendingPathComponent("Alloy/settings.json")
        return (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }

    private func messages(_ folder: URL) -> String {
        (try? String(contentsOf: folder.appendingPathComponent("log.jsonl"), encoding: .utf8)) ?? ""
    }

    @Test func secretReachesTheProcessOnlyAsItsEnv() async throws {
        let (p, folder) = try rig(script: .object(["logEnv": .array([.string("TODO_TOKEN")])]))
        try p.coordinator.setSecret(Self.value, key: "token", for: Self.id)
        #expect(await p.coordinator.activate(plugin: Self.id, .command))
        let envFile = folder.appendingPathComponent("log.jsonl.env")
        #expect(await waitFor { FileManager.default.fileExists(atPath: envFile.path) })
        let env = try #require(JSONValue.parse(try Data(contentsOf: envFile)))
        #expect(env["TODO_TOKEN"]?.stringValue == Self.value)
        #expect(await waitFor { messages(folder).contains("initialize") })
        #expect(!messages(folder).contains(Self.value), "the secret reached a protocol message")
        let settingsText = settingsText(p)
        #expect(!settingsText.contains(Self.value))
        await p.coordinator.shutdown()
    }

    @Test func secretIsNotInSettingsFile() async throws {
        let (p, _) = try rig()
        try p.coordinator.setSecret(Self.value, key: "token", for: Self.id)
        #expect(p.rig.workspace.settings.plugins[Self.id]?.values["token"] == nil)
        let text = settingsText(p)
        #expect(!text.contains(Self.value))
        #expect(throws: (any Error).self) { try p.coordinator.setValue(.string(Self.value), key: "token", for: Self.id) }
        #expect(try p.secrets.get(agent: Self.id, variable: "token") == Self.value)
    }

    @Test func theLogKeepsTheNewestFiftyLinesAndHidesSecrets() async throws {
        let (p, _) = try rig()
        try p.coordinator.setSecret(Self.value, key: "token", for: Self.id)
        #expect(await p.coordinator.activate(plugin: Self.id, .command))
        for i in 0..<120 { p.coordinator.appendLog(plugin: Self.id, "line \(i) with \(Self.value)") }
        let lines = try #require(p.coordinator.commandErrors[Self.id])
        #expect(lines.count == PluginCoordinator.maxLogLines)
        #expect(lines.first?.hasPrefix("line 70 ") == true && lines.last?.hasPrefix("line 119 ") == true, "\(lines.first ?? "")")
        let text = await p.coordinator.logText(for: Self.id)
        #expect(!text.contains(Self.value), "the secret reached the log")
        #expect(text.contains(PluginLogRedactor.marker))
        await p.coordinator.shutdown()
    }

    @Test func commandOutcomesAreCapped() async throws {
        let (p, _) = try rig()
        for i in 0..<(PluginCoordinator.maxLogLines + 30) { p.coordinator.commandOutcomes.append((Self.id, "c\(i)", nil)) }
        #expect(p.coordinator.commandOutcomes.count == PluginCoordinator.maxLogLines)
        #expect(p.coordinator.commandOutcomes.last?.command == "c\(PluginCoordinator.maxLogLines + 29)")
    }

    @Test func logTailRedactsTheSecret() async throws {
        let (p, _) = try rig(script: .object(["stderrEnv": .array([.string("TODO_TOKEN")])]))
        try p.coordinator.setSecret(Self.value, key: "token", for: Self.id)
        #expect(await p.coordinator.activate(plugin: Self.id, .command))
        #expect(await waitFor { await p.coordinator.host?.stderrTail(of: Self.id).contains("TODO_TOKEN") == true })
        let text = await p.coordinator.logText(for: Self.id)
        #expect(text.contains(PluginLogRedactor.marker), "\(text)")
        #expect(!text.contains(Self.value))
        await p.coordinator.shutdown()
    }

    @Test func savingASecretStopsTheProcess() async throws {
        let (p, _) = try rig()
        #expect(await p.coordinator.activate(plugin: Self.id, .command))
        #expect(await p.coordinator.host?.runningCount == 1)
        try p.coordinator.setSecret(Self.value, key: "token", for: Self.id)
        #expect(await waitFor { await p.coordinator.host?.runningCount == 0 })
        try p.coordinator.clearSecret(key: "token", for: Self.id)
        #expect(try p.secrets.get(agent: Self.id, variable: "token") == nil)
        await p.coordinator.shutdown()
    }

    @Test func removeDeletesItsSecrets() async throws {
        let (p, _) = try rig()
        try p.coordinator.setSecret(Self.value, key: "token", for: Self.id)
        #expect(try p.secrets.names(agent: Self.id) == ["token"])
        try await p.coordinator.remove(Self.id)
        #expect(try p.secrets.names(agent: Self.id).isEmpty)
    }

    @Test func unknownSecretKeyIsRefused() async throws {
        let (p, _) = try rig()
        #expect(throws: (any Error).self) { try p.coordinator.setSecret(Self.value, key: "nope", for: Self.id) }
        #expect(try p.secrets.names(agent: Self.id).isEmpty)
    }

    private func settingsWindow(_ p: PluginRig) async throws -> TestWindow {
        testCenter(for: p.rig.workspace).plugins = p.coordinator
        let main = try alloyWindow(p.rig.workspace)
        let settings = try main.openSettingsFromMenu()
        let row = "settings.plugins.row.\(Self.id)"
        for _ in 0..<300 where (try? settings.element(identifier: row)) == nil { settings.tick(); try await Task.sleep(for: .milliseconds(10)) }
        let disclosure = try settings.element(identifier: "settings.plugins.settings.\(Self.id)")
        let label = try #require(descendants(of: disclosure, in: settings).first { $0.label == "Settings" })
        try settings.click(label)
        for _ in 0..<4 { settings.tick() }
        return settings
    }

    @Test func unavailableStoreShowsUnavailable() async throws {
        let (p, _) = try rig(secrets: UnavailableSecretStore())
        let settings = try await settingsWindow(p)
        let note = try settings.element(identifier: "settings.plugins.secret-unavailable.\(Self.id).token")
        #expect((note.value ?? note.label ?? "") == "Secrets need the Keychain, which is unavailable here.")
        #expect((try? settings.element(identifier: "settings.plugins.secret-save.\(Self.id).token")) == nil)
    }

    @Test func settingsSavesAndRemovesThroughTheFields() async throws {
        let (p, _) = try rig()
        let settings = try await settingsWindow(p)
        let field = try settings.element(identifier: "settings.plugins.value.\(Self.id).token")
        try settings.typeText(Self.value, into: field)
        try settings.click(settings.element(identifier: "settings.plugins.secret-save.\(Self.id).token"))
        for _ in 0..<4 { settings.tick() }
        #expect(try p.secrets.get(agent: Self.id, variable: "token") == Self.value)
        #expect((try? settings.element(identifier: "settings.plugins.secret-stored.\(Self.id).token")) != nil)
        let after = try settings.element(identifier: "settings.plugins.value.\(Self.id).token")
        #expect(!(after.value ?? "").contains(Self.value), "the field resets after Save")
        try settings.click(settings.element(identifier: "settings.plugins.secret-remove.\(Self.id).token"))
        for _ in 0..<4 { settings.tick() }
        #expect(try p.secrets.get(agent: Self.id, variable: "token") == nil)
        #expect((try? settings.element(identifier: "settings.plugins.secret-stored.\(Self.id).token")) == nil)
    }

    @Test func keychainServiceIsPluginService() {
        #expect(PluginCoordinator.pluginSecretService == "dev.alloy.plugin-secret")
        let store = systemSecretStore(service: PluginCoordinator.pluginSecretService)
        #expect((store as? KeychainSecretStore)?.serviceName == "dev.alloy.plugin-secret")
    }

    @Test func idleSettingsWithSecretFieldCostNothing() async throws {
        let (p, _) = try rig()
        let settings = try await settingsWindow(p)
        for _ in 0..<15 { settings.tick(); await Task.yield() }
        settings.resetFrameWork()
        for _ in 0..<20 { settings.tick(); await Task.yield() }
        let requests = settings.frameWork.reduce(0) { $0 + $1.elementRequests }
        #expect(requests == 0, "idle frames with the secret field requested \(requests) elements")
    }
}
