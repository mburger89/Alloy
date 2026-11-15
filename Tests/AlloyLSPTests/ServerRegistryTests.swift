import AlloyCore
import Foundation
import Testing
@testable import AlloyLSP

@Suite struct ServerRegistryTests {
    private final class Counter: @unchecked Sendable {
        private let lock = NSLock(); private var n = 0
        func bump() { lock.lock(); n += 1; lock.unlock() }
        var value: Int { lock.lock(); defer { lock.unlock() }; return n }
    }

    private func tempDir() throws -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("alloy-reg-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    private func makeExecutable(_ name: String, in dir: URL) throws -> String {
        let p = dir.appendingPathComponent(name)
        try "#!/bin/sh\nexit 0\n".write(to: p, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: p.path)
        return p.path
    }

    // MARK: Linters

    @Test func lintersAreFoundBesideTheMainServer() {
        let r = ServerRegistry(overrides: [:])
        #expect(r.server(forPath: "a.py")?.id == "pyright")
        #expect(r.linters(forPath: "a.py").map(\.id) == ["ruff"])
    }

    @Test func lintersNeverWinMainLookup() {
        let r = ServerRegistry(overrides: [:])
        #expect(r.server(forPath: "a.ts")?.id == "typescript-language-server")
        #expect(r.linters(forPath: "a.ts").map(\.id) == ["eslint", "biome"])
        #expect(r.languageID(forPath: "a.tsx") == "typescriptreact")
    }

    @Test func disabledLinterIsNotListed() {
        let r = ServerRegistry(overrides: ["ruff": ServerConfigOverride(enabled: false)])
        #expect(r.linters(forPath: "a.py").isEmpty)
    }

    @Test func userAddedLinterWithRole() {
        let r = ServerRegistry(overrides: ["mylint": ServerConfigOverride(extensions: ["py"], command: "mylint", role: .linter)])
        #expect(r.linters(forPath: "a.py").map(\.id) == ["ruff", "mylint"])
        #expect(r.server(forPath: "a.py")?.id == "pyright")
    }

    @Test func roleOverrideMovesBuiltIn() {
        let r = ServerRegistry(overrides: ["ruff": ServerConfigOverride(role: .main)])
        #expect(r.server(forPath: "a.py")?.id == "ruff")
        #expect(r.linters(forPath: "a.py").isEmpty)
    }

    @Test func unknownRoleIsIgnored() throws {
        let json = #"{"role":"banana","command":"x","enabled":false}"#
        let o = try JSONDecoder().decode(ServerConfigOverride.self, from: Data(json.utf8))
        #expect(o.role == nil)
        #expect(o.command == "x")
        let r = ServerRegistry(overrides: ["ruff": o])
        #expect(r.all.first { $0.id == "ruff" }?.role == .linter)
    }

    @Test func clippyMergesIntoInitOptions() {
        let r = ServerRegistry(overrides: ["rust-analyzer": ServerConfigOverride(clippy: true)])
        let ra = r.all.first { $0.id == "rust-analyzer" }!
        #expect(ServerRegistry.effectiveInitializationOptions(ra)?["check"]?["command"]?.stringValue == "clippy")

        let own = JSONValue.object(["check": .object(["command": .string("check")]), "x": .number(1)])
        let r2 = ServerRegistry(overrides: ["rust-analyzer": ServerConfigOverride(initializationOptions: own, clippy: true)])
        let ra2 = r2.all.first { $0.id == "rust-analyzer" }!
        let eff = ServerRegistry.effectiveInitializationOptions(ra2)
        #expect(eff?["check"]?["command"]?.stringValue == "check")
        #expect(eff?["x"]?.intValue == 1)

        let off = ServerRegistry(overrides: [:]).all.first { $0.id == "rust-analyzer" }!
        #expect(ServerRegistry.effectiveInitializationOptions(off) == nil)
    }

    @Test func efmHasNoBuiltInFiles() {
        let r = ServerRegistry(overrides: [:])
        #expect(r.linters(forPath: "a.swift").contains { $0.id == "efm" } == false)
        let e = r.all.first { $0.id == "efm" }
        #expect(e?.role == .linter)
        #expect(e?.extensions.isEmpty == true)
    }

    @Test func builtInLinterRows() {
        let r = ServerRegistry(overrides: [:])
        let eslint = r.all.first { $0.id == "eslint" }!
        #expect(eslint.arguments == ["--stdio"])
        #expect(eslint.requiresConfigFiles == ["eslint.config.*", ".eslintrc", ".eslintrc.*", "package.json#eslintConfig"])
        #expect(eslint.configurationAnswers[""]?["validate"]?.stringValue == "on")
        #expect(eslint.configurationAnswers[""]?["onIgnoredFiles"]?.stringValue == "off")
        #expect(eslint.configurationAnswers[""]?["quiet"] == .bool(false))
        #expect(eslint.configurationAnswers[""]?["format"] == .bool(false))
        #expect(eslint.configurationAnswers[""]?["codeActionOnSave"] == .object(["enable": .bool(false), "mode": .string("all")]))
        #expect(eslint.languageIDs["ts"] == "typescript")
        #expect(r.all.first { $0.id == "biome" }?.requiresConfigFiles == ["biome.json", "biome.jsonc"])
        #expect(r.all.first { $0.id == "golangci-lint" }?.initializationOptions?["command"] != nil)
    }

    @Test func serverConfigDecodesWithoutNewFields() throws {
        let json = #"{"id":"a","name":"A","languageID":"x","languageIDs":{},"extensions":[],"fileNames":[],"command":"a","arguments":[],"enabled":true}"#
        let c = try JSONDecoder().decode(ServerConfig.self, from: Data(json.utf8))
        #expect(c.role == .main && c.configurationAnswers.isEmpty && c.requiresConfigFiles.isEmpty && !c.clippy)
    }

    @Test func matchesByExtensionAndFileName() {
        let r = ServerRegistry(overrides: [:])
        #expect(r.server(forPath: "src/a.RS")?.id == "rust-analyzer")
        #expect(r.server(forPath: "/x/Gemfile")?.id == "ruby-lsp")
        #expect(r.server(forPath: "notes.txt") == nil)
        #expect(r.server(forPath: "Makefile") == nil)
        #expect(r.server(forPath: "a.tsx")?.arguments == ["--stdio"])
        #expect(r.server(forPath: "a.h")?.id == "clangd")
    }

    @Test func overrideReplacesCommandAndCanDisable() {
        let r = ServerRegistry(overrides: [
            "rust-analyzer": ServerConfigOverride(command: "/opt/ra", arguments: ["-v"]),
            "gopls": ServerConfigOverride(enabled: false),
        ])
        let ra = r.server(forPath: "a.rs")
        #expect(ra?.command == "/opt/ra")
        #expect(ra?.arguments == ["-v"])
        #expect(r.server(forPath: "a.go") == nil)
        #expect(r.all.contains { $0.id == "gopls" && !$0.enabled })
    }

    @Test func unknownOverrideIdAddsServer() {
        let r = ServerRegistry(overrides: [
            "my-ls": ServerConfigOverride(extensions: ["foo"], command: "my-ls"),
            "incomplete": ServerConfigOverride(extensions: ["bar"]),
        ])
        let s = r.server(forPath: "x.foo")
        #expect(s?.id == "my-ls")
        #expect(s?.command == "my-ls")
        #expect(r.server(forPath: "x.bar") == nil)
    }

    @Test func overriddenExtensionBeatsBuiltIn() {
        let r = ServerRegistry(overrides: ["my-ls": ServerConfigOverride(extensions: ["rs"], command: "my-ls")])
        #expect(r.server(forPath: "a.rs")?.id == "my-ls")
    }

    @Test func locatorSearchesLoginPATHAndCaches() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let exe = try makeExecutable("fake-ls", in: dir)
        let calls = Counter()
        let loc = ServerLocator(loginPATH: { calls.bump(); return "/nonexistent:\(dir.path)" }, xcrunFind: { _ in nil })
        #expect(loc.resolve("fake-ls") == exe)
        #expect(loc.resolve("fake-ls") == exe)
        #expect(calls.value == 1)
        #expect(loc.resolve("missing-ls") == nil)
        #expect(loc.resolve("missing-ls") == nil)
        #expect(calls.value == 2)
        #expect(loc.resolve(exe) == exe)
        #expect(loc.resolve(dir.appendingPathComponent("nope").path) == nil)
    }

    @Test func locatorIgnoresNonExecutableFiles() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try "x".write(to: dir.appendingPathComponent("plain"), atomically: true, encoding: .utf8)
        let loc = ServerLocator(loginPATH: { dir.path }, xcrunFind: { _ in nil })
        #expect(loc.resolve("plain") == nil)
    }

    @Test func locatorFallsBackToXcrunForSourceKit() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let exe = try makeExecutable("sourcekit-lsp", in: dir)
        let loc = ServerLocator(loginPATH: { "/nonexistent" }, xcrunFind: { $0 == "sourcekit-lsp" ? exe : nil })
        #expect(loc.resolve("sourcekit-lsp") == exe)
        let other = ServerLocator(loginPATH: { "/nonexistent" }, xcrunFind: { _ in exe })
        #expect(other.resolve("gopls") == nil)
    }

    @Test func languageIDsPerExtension() {
        let r = ServerRegistry(overrides: [:])
        let expected: [String: String] = [
            "a.js": "javascript", "a.jsx": "javascriptreact", "a.tsx": "typescriptreact", "a.ts": "typescript",
            "a.mjs": "javascript", "a.cjs": "javascript", "a.c": "c", "a.h": "c", "a.cpp": "cpp", "a.m": "objective-c",
            "a.mm": "objective-cpp", "a.scss": "scss", "a.less": "less", "a.css": "css", "a.jsonc": "jsonc",
            "a.json": "json", "a.rs": "rust", "Gemfile": "ruby", "A.TSX": "typescriptreact",
        ]
        for (path, id) in expected { #expect(r.languageID(forPath: path) == id, "\(path)") }
        #expect(r.languageID(forPath: "notes.txt") == nil)
    }

    @Test func overrideSuppliesLanguageIDs() {
        let r = ServerRegistry(overrides: [
            "rust-analyzer": ServerConfigOverride(languageIDs: ["rs": "rust2"]),
            "my-ls": ServerConfigOverride(languageID: "foo", languageIDs: ["bar": "foobar"], extensions: ["foo", "bar"], command: "my-ls"),
        ])
        #expect(r.languageID(forPath: "a.rs") == "rust2")
        #expect(r.languageID(forPath: "a.foo") == "foo")
        #expect(r.languageID(forPath: "a.bar") == "foobar")
    }

    @Test func invalidateClearsMissesAndRereadsLoginPATH() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let resets = Counter()
        let loc = ServerLocator(loginPATH: { dir.path }, xcrunFind: { _ in nil }, resetLoginPATH: { resets.bump() })
        #expect(loc.resolve("late-ls") == nil)
        let exe = try makeExecutable("late-ls", in: dir)
        #expect(loc.resolve("late-ls") == nil)  // cached miss
        loc.invalidate()
        #expect(resets.value == 1)
        #expect(loc.resolve("late-ls") == exe)
    }

    @Test func unavailableLoginPATHFallsBackAndDoesNotCacheMisses() throws {
        let home = try tempDir(), proc = try tempDir()
        defer { try? FileManager.default.removeItem(at: home); try? FileManager.default.removeItem(at: proc) }
        let cargo = home.appendingPathComponent(".cargo/bin")
        try FileManager.default.createDirectory(at: cargo, withIntermediateDirectories: true)
        let loc = ServerLocator(loginPATH: { nil }, xcrunFind: { _ in nil }, processPATH: proc.path, home: home.path)
        #expect(loc.resolve("fb-ls") == nil)
        let inCargo = try makeExecutable("fb-ls", in: cargo)
        #expect(loc.resolve("fb-ls") == inCargo)  // the miss was not cached
        let inProc = try makeExecutable("proc-ls", in: proc)
        #expect(loc.resolve("proc-ls") == inProc)
    }

    @Test func tildeCommandExpandsToHome() throws {
        let home = try tempDir()
        defer { try? FileManager.default.removeItem(at: home) }
        let exe = try makeExecutable("tilde-ls", in: home)
        let loc = ServerLocator(loginPATH: { "/nonexistent" }, xcrunFind: { _ in nil }, home: home.path)
        #expect(loc.resolve("~/tilde-ls") == exe)
    }

    @Test func runToolIsBoundedByTimeout() {
        let start = Date()
        #expect(ServerLocator.runTool("/bin/sleep", ["30"], timeout: 0.3) == nil)
        #expect(Date().timeIntervalSince(start) < 10)
        #expect(ServerLocator.runTool("/bin/echo", ["hi"], timeout: 5) == "hi")
    }
}
