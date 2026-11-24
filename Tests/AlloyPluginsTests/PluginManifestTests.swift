import Foundation
import Testing
import AlloyCore
@testable import AlloyPlugins

@Suite("PluginManifest")
struct PluginManifestTests {
    private let t = PluginTestFolder()

    private func manifest(_ extra: String = "", id: String = "dev.example.tool") -> String {
        #"{"id":"\#(id)","name":"Tool","version":"1.2.3","apiVersion":1"# + (extra.isEmpty ? "" : "," + extra) + "}"
    }

    private func load(_ extra: String = "", id: String = "dev.example.tool", pathDirs: [String] = [],
                      prepare: (URL) -> Void = { _ in }) -> Result<PluginManifest, PluginManifestError> {
        let dir = t.plugin(id, manifest: manifest(extra, id: id))
        prepare(dir)
        return PluginManifestLoader.load(folder: dir, pathDirs: pathDirs)
    }

    private func failure(_ r: Result<PluginManifest, PluginManifestError>) -> PluginManifestError? {
        if case .failure(let e) = r { return e }
        return nil
    }

    @Test func validDeclarativeManifestLoads() throws {
        let r = load(#""description":"d","permissions":["process.spawn"],"contributes":{"settings":[{"key":"mode","title":"Mode","type":"enum","options":["a","b"],"default":"a"}],"taskCommands":[{"id":"build","title":"Build","command":"make","args":["all"]}],"languageServers":{"my-ls":{"command":"ls","extensions":["x"]}}}"#)
        let m = try r.get()
        #expect(m.id == "dev.example.tool" && m.version == "1.2.3" && !m.isScripted)
        #expect(m.permissions == [.processSpawn])
        #expect(m.contributes.settings.first?.type == .enumeration(["a", "b"]))
        #expect(m.contributes.taskCommands.first?.args == ["all"])
        #expect(m.contributes.languageServers["my-ls"]?.command == "ls")
    }

    @Test func validScriptedManifestLoads() throws {
        let r = load(#""main":{"command":"run.sh","args":["--x"]},"activationEvents":["onCommand:hi","onLanguage:swift","onStartup"],"contributes":{"commands":[{"id":"hi","title":"Hi","shortcut":"cmd+shift+h","menu":"plugins","when":"language:swift"}],"panels":[{"id":"p","title":"P"}],"mcpTools":[{"name":"look","description":"d","inputSchema":{"type":"object"}}]},"permissions":["mcp.tools"]"#) { dir in
            t.file("run.sh", in: dir, executable: true)
        }
        let m = try r.get()
        #expect(m.isScripted && m.main == PluginMain(command: "run.sh", args: ["--x"]))
        #expect(m.activationEvents == [.command("hi"), .language("swift"), .startup])
        #expect(m.contributes.commands.first?.when == .language("swift"))
        #expect(m.contributes.commands.first?.inPluginsMenu == true)
        #expect(m.contributes.commands.first?.shortcut != nil)
    }

    @Test func unknownTopLevelKeyIsRejected() {
        #expect(failure(load(#""colour":"red""#)) == .unknownKey("colour"))
    }

    @Test func unknownContributionKeyIsRejected() {
        #expect(failure(load(#""contributes":{"snippets":[]}"#)) == .unknownKey("contributes.snippets"))
    }

    @Test func idMustMatchFolder() {
        let dir = t.plugin("dev.other.name", manifest: manifest())
        #expect(failure(PluginManifestLoader.load(folder: dir, pathDirs: [])) != nil)
    }

    @Test func badSemverIsRejected() {
        let dir = t.plugin("dev.example.tool", manifest: #"{"id":"dev.example.tool","name":"T","version":"1.2"}"#)
        #expect(failure(PluginManifestLoader.load(folder: dir, pathDirs: [])) == .invalidField("version", "1.2"))
    }

    @Test func otherApiVersionStillLoads() throws {
        let dir = t.plugin("dev.example.tool", manifest: #"{"id":"dev.example.tool","name":"T","version":"1.0.0","apiVersion":2}"#)
        let m = try PluginManifestLoader.load(folder: dir, pathDirs: []).get()
        #expect(m.apiVersion == 2)
    }

    @Test func absoluteMainIsOutside() {
        #expect(failure(load(#""main":{"command":"/bin/sh"}"#)) == .mainOutsideFolder)
    }

    @Test func dotDotMainIsOutside() {
        #expect(failure(load(#""main":{"command":"../x.sh"}"#)) == .mainOutsideFolder)
    }

    @Test func symlinkedMainEscapingIsOutside() {
        let r = load(#""main":{"command":"link.sh"}"#) { dir in
            try? FileManager.default.createSymbolicLink(atPath: dir.appendingPathComponent("link.sh").path, withDestinationPath: "/bin/sh")
        }
        #expect(failure(r) == .mainOutsideFolder)
    }

    @Test func missingMain() {
        #expect(failure(load(#""main":{"command":"nope.sh"}"#)) == .mainMissing)
    }

    @Test func nonExecutableMain() {
        let r = load(#""main":{"command":"run.sh"}"#) { t.file("run.sh", in: $0, executable: false) }
        #expect(failure(r) == .mainNotExecutable)
    }

    @Test func bareInterpreterFoundOnPath() throws {
        let bin = t.root.appendingPathComponent("bin")
        t.file("python3", in: bin, executable: true)
        let r = load(#""main":{"command":"python3","args":["main.py"]}"#, pathDirs: [bin.path])
        #expect(try r.get().main?.command == "python3")
    }

    @Test func bareInterpreterNotOnPath() {
        #expect(failure(load(#""main":{"command":"node"}"#, pathDirs: [t.root.path])) == .mainNotFoundOnPath("node"))
    }

    @Test func commandsWithoutMainNeedMain() {
        #expect(failure(load(#""contributes":{"commands":[{"id":"a","title":"A"}]}"#)) == .needsMain("commands"))
    }

    @Test func serversWithoutSpawnNeedPermission() {
        #expect(failure(load(#""contributes":{"languageServers":{"my-ls":{"command":"x"}}}"#)) == .missingPermission(.processSpawn))
    }

    @Test func oversizeManifest() {
        let dir = t.plugin("dev.example.tool", manifest: String(repeating: " ", count: 257 * 1024))
        #expect(failure(PluginManifestLoader.load(folder: dir, pathDirs: [])) == .tooLarge)
    }

    @Test func missingManifestAndNotJSON() {
        let dir = t.root.appendingPathComponent("dev.empty.one")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        #expect(failure(PluginManifestLoader.load(folder: dir, pathDirs: [])) == .missingManifest)
        let bad = t.plugin("dev.bad.json", manifest: "{nope")
        #expect(failure(PluginManifestLoader.load(folder: bad, pathDirs: [])) == .notJSON)
    }

    @Test func duplicateCommandId() {
        let r = load(#""main":{"command":"run.sh"},"contributes":{"commands":[{"id":"a","title":"A"},{"id":"a","title":"B"}]}"#) {
            t.file("run.sh", in: $0, executable: true)
        }
        #expect(failure(r) == .duplicate("commands.a"))
    }

    @Test func badWhenIsRejected() {
        let r = load(#""main":{"command":"run.sh"},"contributes":{"commands":[{"id":"a","title":"A","when":"sometimes"}]}"#) {
            t.file("run.sh", in: $0, executable: true)
        }
        #expect(failure(r) != nil)
    }

    @Test func badShortcutIsRejected() {
        let r = load(#""main":{"command":"run.sh"},"contributes":{"commands":[{"id":"a","title":"A","shortcut":"cmd+"}]}"#) {
            t.file("run.sh", in: $0, executable: true)
        }
        #expect(failure(r) != nil)
    }

    @Test func themePathMustStayInside() {
        #expect(failure(load(#""contributes":{"themes":[{"path":"../t.json"}]}"#)) != nil)
        #expect(failure(load(#""contributes":{"themes":[{"path":"t.txt"}]}"#)) != nil)
    }

    private func secret(_ item: String) -> Result<PluginManifest, PluginManifestError> {
        load(#""contributes":{"settings":[\#(item)]}"#)
    }

    @Test func secretSettingParses() throws {
        let m = try secret(#"{"key":"token","title":"API token","type":"secret","env":"TODO_TOKEN"}"#).get()
        #expect(m.contributes.settings.first?.type == .secret(env: "TODO_TOKEN"))
        #expect(m.contributes.settings.first?.defaultValue == nil)
    }

    @Test func secretWithReservedEnvIsRejected() {
        for env in ["PATH", "HOME", "LANG", "TMPDIR", "SHELL", "USER", "ALLOY_TOKEN", "DYLD_X", "LD_PRELOAD", "lower", "1ABC", ""] {
            #expect(failure(secret(#"{"key":"t","title":"T","type":"secret","env":"\#(env)"}"#)) != nil, "env \(env)")
        }
        #expect(failure(secret(#"{"key":"t","title":"T","type":"secret"}"#)) != nil, "env is required")
        #expect(failure(secret(#"{"key":"t","title":"T","type":"string","env":"X"}"#)) != nil, "env only for secrets")
    }

    @Test func secretWithDefaultIsRejected() {
        #expect(failure(secret(#"{"key":"t","title":"T","type":"secret","env":"TODO_TOKEN","default":"x"}"#)) != nil)
    }
}
