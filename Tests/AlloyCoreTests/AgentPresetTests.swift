import AlloyCore
import Foundation
import Testing

@Suite struct AgentPresetTests {
    @Test func presetsHaveSpecCommands() {
        func line(_ id: String) -> String {
            let d = AgentPresets.preset(id: id)!
            return ([d.command] + d.args).joined(separator: " ")
        }
        #expect(AgentPresets.all.map(\.id) == ["codex", "gemini", "opencode", "goose"])
        #expect(line("codex") == "codex-acp")
        #expect(line("gemini") == "gemini --acp")
        #expect(line("opencode") == "opencode acp")
        #expect(line("goose") == "goose acp")
        #expect(AgentPresets.preset(id: "codex")?.installHint == "npm install -g @agentclientprotocol/codex-acp")
        #expect(AgentPresets.geminiFallbackArgs == ["--experimental-acp"])
        #expect(AgentPresets.all.allSatisfy { $0.isPreset && (try? $0.validate()) != nil })
    }

    @Test func secretLookingEnvIsRefusedWithExactMessage() {
        for name in ["API_KEY", "my_token", "ClientSecret", "DB_PASSWORD", "aws_Credentials", "apikey"] {
            let def = AgentDefinition(id: "x", name: "X", command: "x", env: [EnvVar(name: name, value: "v")])
            #expect(throws: AgentDefinitionError.self) { try def.validate() }
            do { try def.validate() } catch {
                #expect(error.localizedDescription == "Add this under Secrets; Alloy keeps it in your Keychain.")
            }
        }
        let ok = AgentDefinition(id: "x", name: "X", command: "x", env: [EnvVar(name: "OLLAMA_HOST", value: "h")])
        #expect((try? ok.validate()) != nil)
    }

    @Test func settingsRecordsSecretNamesNeverValues() throws {
        let store = InMemorySecretStore()
        try store.set("hunter2", agent: "mine", variable: "MY_API_KEY")
        let def = AgentDefinition(id: "mine", name: "Mine", command: "mine", secretNames: ["MY_API_KEY"])
        let settings = AlloySettings(agents: [def], defaultAgentID: "mine")
        let json = String(decoding: try JSONEncoder().encode(settings), as: UTF8.self)
        #expect(json.contains("MY_API_KEY"))
        #expect(!json.contains("hunter2"))
        let back = try JSONDecoder().decode(AlloySettings.self, from: Data(json.utf8))
        #expect(back.agents == [def] && back.defaultAgentID == "mine")
    }

    @Test func oldSettingsFileWithoutAgentsStillDecodes() throws {
        let s = try JSONDecoder().decode(AlloySettings.self, from: Data(#"{"theme":"nord","shareKnowledge":false}"#.utf8))
        #expect(s.theme == "nord" && !s.shareKnowledge && s.agents.isEmpty && s.defaultAgentID == nil)
        let mixed = try JSONDecoder().decode(AlloySettings.self, from: Data(#"{"agents":[{"id":1},{"id":"a","name":"A","command":"a","args":[],"env":[],"secretNames":[],"isPreset":false}]}"#.utf8))
        #expect(mixed.agents.map(\.id) == ["a"])
    }
}
