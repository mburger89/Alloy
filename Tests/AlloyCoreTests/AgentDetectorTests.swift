import AlloyCore
import Foundation
import Testing

@Suite struct AgentDetectorTests {
    @Test func detectsInstalledAndMissingWithHint() {
        let detector = AgentDetector(resolve: { names in
            #expect(names.contains("codex-acp") && names.contains("goose"))
            return ["codex-acp": "/bin/x/codex-acp"]
        }, isExecutable: { $0 == "/bin/x/codex-acp" || $0 == "/opt/homebrew/bin/opencode" }, home: "/home/me")
        let statuses = detector.detect(AgentPresets.all)
        #expect(statuses[0] == .installed(URL(fileURLWithPath: "/bin/x/codex-acp")))
        #expect(statuses[1] == .missing(installHint: "npm install -g @google/gemini-cli"))
        #expect(statuses[2] == .installed(URL(fileURLWithPath: "/opt/homebrew/bin/opencode")))
        let custom = AgentDefinition(id: "c", name: "C", command: "/abs/c")
        #expect(AgentDetector(resolve: { _ in [:] }, isExecutable: { $0 == "/abs/c" }).detect([custom])
                == [.installed(URL(fileURLWithPath: "/abs/c"))])
    }

    @Test func geminiFallsBackToExperimentalAcpWhenAcpRejected() {
        #expect(AgentDetector.geminiArgs(helpOutput: "Options:\n  --acp  Starts in ACP mode\n") == ["--acp"])
        #expect(AgentDetector.geminiArgs(helpOutput: "Options:\n  --experimental-acp  Start ACP\n") == ["--experimental-acp"])
        let gemini = AgentPresets.preset(id: "gemini")!
        let url = URL(fileURLWithPath: "/bin/gemini")
        #expect(AgentDetector(helpRunner: { _ in "--experimental-acp" }).launchArgs(for: gemini, executable: url) == ["--experimental-acp"])
        #expect(AgentDetector(helpRunner: { _ in "--acp" }).launchArgs(for: gemini, executable: url) == ["--acp"])
        #expect(AgentDetector(helpRunner: { _ in nil }).launchArgs(for: gemini, executable: url) == ["--acp"])
        let goose = AgentPresets.preset(id: "goose")!
        #expect(AgentDetector(helpRunner: { _ in "x" }).launchArgs(for: goose, executable: url) == ["acp"])
    }

    @Test func loginShellOutputParsesAndAsksOnce() {
        #expect(CommandLocator.parse("banner\nALLOY_CMD codex-acp /a/codex-acp\nALLOY_CMD goose \n") == ["codex-acp": "/a/codex-acp"])
        nonisolated(unsafe) var calls = 0
        let run: (String) -> String? = { script in
            calls += 1
            #expect(script.contains("qq-one qq-two") && !script.contains(";;"))
            return "ALLOY_CMD qq-one /z/qq-one\nALLOY_CMD qq-two \n"
        }
        ClaudeLocator.resetLoginShellCache()
        #expect(CommandLocator.loginShellLookup(names: ["qq-one", "qq-two", "bad name;rm"], run: run) == ["qq-one": "/z/qq-one"])
        #expect(CommandLocator.loginShellLookup(names: ["qq-one", "qq-two"], run: run) == ["qq-one": "/z/qq-one"])
        #expect(calls == 1)
        ClaudeLocator.resetLoginShellCache()
        _ = CommandLocator.loginShellLookup(names: ["qq-one", "qq-two"], run: run)
        #expect(calls == 2)
    }
}
