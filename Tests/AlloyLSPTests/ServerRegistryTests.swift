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
