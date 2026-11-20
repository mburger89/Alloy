import AlloyCore
import Foundation
import Testing

private struct DenyingStore: AgentSecretStore {
    func set(_ value: String, agent: String, variable: String) throws { throw SecretStoreError(status: -128) }
    func get(agent: String, variable: String) throws -> String? { throw SecretStoreError(status: -128) }
    func delete(agent: String, variable: String) throws { throw SecretStoreError(status: -128) }
    func deleteAll(agent: String) throws { throw SecretStoreError(status: -128) }
}

@Suite struct AgentSecretsTests {
    @Test func removingAgentOrSecretDeletesItem() throws {
        let store = InMemorySecretStore()
        try store.set("a", agent: "one", variable: "A_KEY")
        try store.set("b", agent: "one", variable: "B_KEY")
        try store.set("c", agent: "two", variable: "A_KEY")
        try store.delete(agent: "one", variable: "A_KEY")
        #expect(try store.get(agent: "one", variable: "A_KEY") == nil)
        #expect(try store.get(agent: "one", variable: "B_KEY") == "b")
        let def = AgentDefinition(id: "one", name: "One", command: "one", secretNames: ["B_KEY"])
        try def.removeSecrets(from: store)
        #expect(try store.get(agent: "one", variable: "B_KEY") == nil)
        #expect(try store.get(agent: "two", variable: "A_KEY") == "c")
    }

    @Test func resolveReadsSecretsAndPlainVariables() throws {
        let store = InMemorySecretStore()
        try store.set("s3", agent: "x", variable: "X_TOKEN")
        let def = AgentDefinition(id: "x", name: "X", command: "x", env: [EnvVar(name: "HOST", value: "h")],
                                  secretNames: ["X_TOKEN", "OTHER_KEY"])
        let r = def.resolveEnvironment(store: store)
        #expect(r.env == ["HOST": "h", "X_TOKEN": "s3"])
        #expect(r.missing == ["OTHER_KEY"])
    }

    @Test func deniedKeychainLaunchesWithoutSecretAndNamesMissing() {
        let def = AgentDefinition(id: "x", name: "X", command: "x", env: [EnvVar(name: "HOST", value: "h")],
                                  secretNames: ["X_TOKEN"])
        let r = def.resolveEnvironment(store: DenyingStore())
        #expect(r.env == ["HOST": "h"])
        #expect(r.missing == ["X_TOKEN"])
        #expect(!(SecretStoreError(status: -128).errorDescription ?? "").contains("hunter2"))
    }

    @Test func secretSourcesNeverWriteFiles() throws {
        let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/AlloyCore/Agents")
        for name in ["AgentDefinition", "AgentPresets", "AgentDetector", "AgentSecrets"] {
            let text = try String(contentsOf: dir.appendingPathComponent("\(name).swift"), encoding: .utf8)
            for banned in [".write(to", "createFile", "UserDefaults", "FileHandle(forWriting"] {
                #expect(!text.contains(banned), "\(name) contains \(banned)")
            }
        }
    }
}

@Suite struct StoreNamedSecretTests {
    @Test func everyStoredSecretOfAnAgentIsInjectedAndNeverLeaksToAnother() throws {
        let store = InMemorySecretStore()
        try store.set("g", agent: "gemini", variable: "GEMINI_API_KEY")
        try store.set("o", agent: "codex", variable: "OPENAI_API_KEY")
        let gemini = AgentDefinition(id: "gemini", name: "Gemini", command: "gemini")
        let codex = AgentDefinition(id: "codex", name: "Codex", command: "codex-acp")
        #expect(gemini.resolveEnvironment(store: store).env == ["GEMINI_API_KEY": "g"])
        #expect(codex.resolveEnvironment(store: store).env == ["OPENAI_API_KEY": "o"])
    }

    @Test func legacySecretNamesAreMergedWithTheStoresNames() throws {
        let store = InMemorySecretStore()
        try store.set("a", agent: "x", variable: "OLD_KEY")
        try store.set("b", agent: "x", variable: "NEW_KEY")
        let def = AgentDefinition(id: "x", name: "X", command: "x", secretNames: ["OLD_KEY", "GONE_KEY"])
        let r = def.resolveEnvironment(store: store)
        #expect(r.env == ["OLD_KEY": "a", "NEW_KEY": "b"])
        #expect(r.missing == ["GONE_KEY"])
    }
}
