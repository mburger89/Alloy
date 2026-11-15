import AlloyCore
import AlloyLSPTestSupport
import Foundation
import MetalUICodeBuffer
import Testing
@testable import AlloyLSP

private func diag(_ line: Int, _ ch: Int, _ message: String, source: String? = nil) -> String {
    let src = source.map { #","source":"\#($0)""# } ?? ""
    return #"{"range":{"start":{"line":\#(line),"character":\#(ch)},"end":{"line":\#(line),"character":\#(ch + 1)}},"severity":2,"message":"\#(message)"\#(src)}"#
}

private func script(_ diagnostics: [String], extra: String = "") -> String {
    #"{"capabilities":{"textDocumentSync":2},"diagnostics":[\#(diagnostics.joined(separator: ","))]\#(extra)}"#
}

private func lastDiagnostics(_ seen: Collector, _ path: String) -> (version: Int?, items: [LSPDiagnostic])? {
    for result in seen.all.reversed() {
        if case .diagnostics(let p, let v, let items) = result, p == path { return (v, items) }
    }
    return nil
}

@Suite
@MainActor
struct LSPManagerLinterTests {
    private let main = Rig.config("main", ext: "x")
    private let lint = Rig.linter("lint", ext: "x")

    @Test func linterGetsSyncButNotDefinitionOrTokens() async throws {
        let caps = #"{"capabilities":{"textDocumentSync":2,"definitionProvider":true,"semanticTokensProvider":{"legend":{"tokenTypes":["a"],"tokenModifiers":[]},"full":true}}}"#
        try await Rig.run([main, lint], scripts: ["main": caps, "lint": caps]) { rig in
            let buffer = CodeBuffer("abc\n")
            let cursor = buffer.makeEditCursor()
            await rig.manager.documentOpened(path: "f.x", snapshot: buffer.snapshot())
            #expect(await waitUntil { rig.methods("lint").contains("textDocument/didOpen") })
            buffer.replace(0..<0, with: "z", origin: .typing)
            guard case .edits(let edits) = cursor.drain() else { Issue.record("no edits"); return }
            await rig.manager.documentChanged(path: "f.x", change: .edits(edits, after: buffer.snapshot()))
            await rig.manager.documentSaved(path: "f.x")
            #expect(await waitUntil { rig.methods("lint").contains("textDocument/didSave") })
            _ = await rig.manager.definitionOutcome(path: "f.x", utf8Offset: 0, snapshot: buffer.snapshot())
            await rig.manager.requestSemanticTokens(path: "f.x")
            await rig.manager.documentClosed(path: "f.x")
            #expect(await waitUntil { rig.methods("lint").contains("textDocument/didClose") })
            let seen = rig.methods("lint")
            for m in ["textDocument/didOpen", "textDocument/didChange", "textDocument/didSave", "textDocument/didClose"] {
                #expect(seen.contains(m), "\(m) missing: \(seen)")
            }
            #expect(!seen.contains("textDocument/definition"))
            #expect(!seen.contains { $0.hasPrefix("textDocument/semanticTokens") })
            #expect(rig.methods("main").contains("textDocument/definition"))
        }
    }

    @Test func diagnosticsFromMainAndLinterAreMerged() async throws {
        try await Rig.run([main, lint], scripts: [
            "main": script([diag(0, 0, "m", source: "main")]),
            "lint": script([diag(0, 1, "l1", source: "lint"), diag(0, 2, "l2", source: "lint")]),
        ]) { rig in
            let seen = Collector(rig.manager.results)
            await rig.manager.documentOpened(path: "f.x", snapshot: snap("abcd\n"))
            #expect(await waitUntil { lastDiagnostics(seen, "f.x")?.items.count == 3 })
            #expect(lastDiagnostics(seen, "f.x")?.items.map(\.message) == ["m", "l1", "l2"])
        }
    }

    @Test func oneServersClearDoesNotWipeAnother() async throws {
        try await Rig.run([main, lint], scripts: [
            "main": script([diag(0, 0, "m", source: "main")]),
            "lint": script([], extra: #","diagnosticsDelayMs":300"#),   // its empty publish strictly follows main's
        ]) { rig in
            let seen = Collector(rig.manager.results)
            await rig.manager.documentOpened(path: "f.x", snapshot: snap("abcd\n"))
            #expect(await waitUntil { seen.all.filter { if case .diagnostics = $0 { true } else { false } }.count >= 2 })
            try await Task.sleep(for: .milliseconds(100))
            let unions = seen.all.compactMap { r -> [String]? in
                if case .diagnostics(_, _, let items) = r { return items.map(\.message) } else { return nil }
            }
            let first = try #require(unions.firstIndex { $0.contains("m") })
            #expect(unions.count >= first + 2, "the linter's clear yielded nothing: \(unions)")
            #expect(unions[first...].allSatisfy { $0.contains("m") }, "\(unions)")
        }
    }

    @Test func missingSourceGetsServerName() async throws {
        try await Rig.run([main, lint], scripts: ["main": script([diag(0, 0, "m")]), "lint": script([diag(0, 1, "l")])]) { rig in
            let seen = Collector(rig.manager.results)
            await rig.manager.documentOpened(path: "f.x", snapshot: snap("abcd\n"))
            #expect(await waitUntil { lastDiagnostics(seen, "f.x")?.items.count == 2 })
            #expect(lastDiagnostics(seen, "f.x")?.items.map(\.source) == ["Fake main", "Lint lint"])
        }
    }

    @Test func staleLinterVersionDoesNotPaintOverNewText() async throws {
        try await Rig.run([main, lint], scripts: [
            "main": script([diag(0, 0, "m", source: "main")]),
            "lint": script([diag(0, 2, "l", source: "lint")], extra: #","diagnosticsVersionLag":1"#),
        ]) { rig in
            let seen = Collector(rig.manager.results)
            let buffer = CodeBuffer("abcd\n")
            let cursor = buffer.makeEditCursor()
            await rig.manager.documentOpened(path: "f.x", snapshot: buffer.snapshot())
            #expect(await waitUntil { lastDiagnostics(seen, "f.x")?.items.count == 2 })
            buffer.replace(0..<0, with: "// hi\n", origin: .typing)   // 6 bytes in front
            guard case .edits(let edits) = cursor.drain() else { Issue.record("no edits"); return }
            let after = buffer.snapshot()
            await rig.manager.documentChanged(path: "f.x", change: .edits(edits, after: after))
            #expect(await waitUntil {
                lastDiagnostics(seen, "f.x").map { $0.version == Int(after.version) && $0.items.count == 2 } ?? false
            })
            let got = try #require(lastDiagnostics(seen, "f.x"))
            // The main set is for the new text as it came; the linter's (published for the old text) moved forward with the edit.
            #expect(got.items.map(\.message) == ["m", "l"])
            #expect(got.items[0].range == 0..<1)
            #expect(got.items[1].range == 8..<9)
        }
    }

    @Test func crashingLinterLeavesMainWorking() async throws {
        try await Rig.run([main, lint], scripts: [
            "main": script([diag(0, 0, "m", source: "main")]),
            "lint": #"{"exitOnInitializeFromLaunch":1}"#,
        ]) { rig in
            let seen = Collector(rig.manager.results)
            await rig.manager.documentOpened(path: "f.x", snapshot: snap("abcd\n"))
            #expect(await waitUntil { seen.states("Lint lint").contains { if case .failed = $0 { true } else { false } } })
            #expect(await waitUntil { lastDiagnostics(seen, "f.x")?.items.map(\.message) == ["m"] })
        }
    }

    @Test func linterOnlyFileIsLintedAndStopsOnClose() async throws {
        try await Rig.run([lint], scripts: ["lint": script([diag(0, 1, "l", source: "lint")])]) { rig in
            let seen = Collector(rig.manager.results)
            let buffer = CodeBuffer("abcd\n")
            let cursor = buffer.makeEditCursor()
            await rig.manager.documentOpened(path: "f.x", snapshot: buffer.snapshot())
            #expect(await waitUntil { lastDiagnostics(seen, "f.x")?.items.map(\.message) == ["l"] })
            buffer.replace(0..<0, with: "z", origin: .typing)
            guard case .edits(let edits) = cursor.drain() else { Issue.record("no edits"); return }
            await rig.manager.documentChanged(path: "f.x", change: .edits(edits, after: buffer.snapshot()))
            await rig.manager.documentSaved(path: "f.x")
            #expect(await waitUntil { rig.methods("lint").contains("textDocument/didSave") })
            #expect(rig.methods("lint").contains("textDocument/didChange"))
            // Without a main server these do nothing.
            _ = await rig.manager.definitionOutcome(path: "f.x", utf8Offset: 0, snapshot: buffer.snapshot())
            await rig.manager.requestSemanticTokens(path: "f.x")
            await rig.manager.documentClosed(path: "f.x")
            #expect(await waitUntil { rig.methods("lint").suffix(2) == ["shutdown", "exit"] })
            #expect(rig.methods("lint").contains("textDocument/didClose"))
            #expect(!rig.methods("lint").contains("textDocument/definition"))
        }
    }

    @Test func reloadMovesAFileToLinterOnlyAndBack() async throws {
        try await Rig.run([main, lint], scripts: [
            "main": script([diag(0, 0, "m", source: "main")]), "lint": script([diag(0, 1, "l", source: "lint")]),
        ]) { rig in
            let seen = Collector(rig.manager.results)
            await rig.manager.documentOpened(path: "f.x", snapshot: snap("abcd\n"))
            #expect(await waitUntil { lastDiagnostics(seen, "f.x")?.items.count == 2 })
            var off = main
            off.enabled = false
            await rig.manager.reload(registry: ServerRegistry(builtIn: [off, lint]))
            #expect(await waitUntil { lastDiagnostics(seen, "f.x")?.items.map(\.message) == ["l"] })
            await rig.manager.documentSaved(path: "f.x")
            #expect(await waitUntil { rig.methods("lint").contains("textDocument/didSave") })
            await rig.manager.reload(registry: ServerRegistry(builtIn: [main, lint]))
            #expect(await waitUntil { lastDiagnostics(seen, "f.x")?.items.count == 2 })
        }
    }

    @Test func failedLinterLosesItsDiagnostics() async throws {
        try await Rig.run([main, lint], scripts: [
            "main": script([diag(0, 0, "m", source: "main")]),
            "lint": script([diag(0, 1, "l", source: "lint")], extra: #","crashAfter":3"#),
        ]) { rig in
            let seen = Collector(rig.manager.results)
            await rig.manager.documentOpened(path: "f.x", snapshot: snap("abcd\n"))
            #expect(await waitUntil { lastDiagnostics(seen, "f.x")?.items.count == 2 })
            #expect(await waitUntil(.seconds(30)) { seen.states("Lint lint").contains { if case .failed = $0 { true } else { false } } })
            #expect(await waitUntil { lastDiagnostics(seen, "f.x")?.items.map(\.message) == ["m"] })
        }
    }

    @Test func disablingLinterRemovesOnlyItsDiagnostics() async throws {
        try await Rig.run([main, lint], scripts: [
            "main": script([diag(0, 0, "m", source: "main")]), "lint": script([diag(0, 1, "l", source: "lint")]),
        ]) { rig in
            let seen = Collector(rig.manager.results)
            await rig.manager.documentOpened(path: "f.x", snapshot: snap("abcd\n"))
            #expect(await waitUntil { lastDiagnostics(seen, "f.x")?.items.count == 2 })
            let mainLaunches = rig.launches.count("main")
            var off = lint
            off.enabled = false
            await rig.manager.reload(registry: ServerRegistry(builtIn: [main, off]))
            #expect(await waitUntil { lastDiagnostics(seen, "f.x")?.items.map(\.message) == ["m"] })
            #expect(await waitUntil { rig.methods("lint").suffix(2) == ["shutdown", "exit"] })
            #expect(rig.launches.count("main") == mainLaunches)
            #expect(!rig.methods("main").contains("shutdown"))
        }
    }

    @Test func eslintStartsOnlyUnderItsConfig() async throws {
        let eslint = Rig.linter("eslint", ext: "ts", requires: ["eslint.config.*"])
        let tsMain = Rig.config("ts", ext: "ts")
        let probe = ConfigProbe(exists: { $0.path.hasSuffix("/web/eslint.config.js") })
        try await Rig.run([tsMain, eslint], probe: probe) { rig in
            await rig.manager.documentOpened(path: "scripts/tool.ts", snapshot: snap("x\n"))
            await rig.manager.documentOpened(path: "web/app.ts", snapshot: snap("x\n"))
            #expect(await waitUntil { rig.openedURIs("eslint").count == 1 })
            #expect(rig.openedURIs("eslint").first?.hasSuffix("/web/app.ts") == true)
            #expect(await waitUntil { rig.openedURIs("ts").count == 2 })
            try await Task.sleep(for: .milliseconds(100))
            #expect(rig.openedURIs("eslint").count == 1)
        }
    }

    @Test func packageJsonEslintConfigCounts() async throws {
        let eslint = Rig.linter("eslint", ext: "ts", requires: ["package.json#eslintConfig"])
        let tsMain = Rig.config("ts", ext: "ts")
        try await Rig.run([tsMain, eslint]) { rig in
            try Data(#"{"name":"a","eslintConfig":{}}"#.utf8).write(to: rig.dir.appendingPathComponent("package.json"))
            await rig.manager.documentOpened(path: "src/app.ts", snapshot: snap("x\n"))
            #expect(await waitUntil { rig.openedURIs("eslint").count == 1 })
        }
        // A package.json without the key does not count; the file is only read when plain names miss.
        try await Rig.run([tsMain, eslint]) { rig in
            try Data(#"{"name":"a"}"#.utf8).write(to: rig.dir.appendingPathComponent("package.json"))
            await rig.manager.documentOpened(path: "app.ts", snapshot: snap("x\n"))
            #expect(await waitUntil { rig.openedURIs("ts").count == 1 })
            try await Task.sleep(for: .milliseconds(150))
            #expect(rig.launches.count("eslint") == 0)
        }
    }

    @Test func packageJsonIsNotReadWhenAPlainConfigIsInTheSameFolder() async throws {
        let dir = URL(fileURLWithPath: "/proj")
        let reads = Flag()
        let probe = ConfigProbe(exists: { _ in true }, read: { _ in reads.value = true; return Data() })
        #expect(probe.hasConfig(for: "a.ts", names: ["eslint.config.*", "package.json#eslintConfig"], root: dir))
        #expect(!reads.value)
        // Without a plain file in that folder, package.json is read.
        let only = ConfigProbe(exists: { $0.lastPathComponent == "package.json" }, read: { _ in reads.value = true; return Data(#"{"eslintConfig":{}}"#.utf8) })
        #expect(only.hasConfig(for: "a.ts", names: ["eslint.config.*", "package.json#eslintConfig"], root: dir))
        #expect(reads.value)
    }

    @Test func editLogStaysEmptyWithoutLinters() async throws {
        try await Rig.run([main]) { rig in
            let buffer = CodeBuffer("abc\n")
            let cursor = buffer.makeEditCursor()
            await rig.manager.documentOpened(path: "f.x", snapshot: buffer.snapshot())
            for _ in 0..<100 {
                buffer.replace(0..<0, with: "z", origin: .typing)
                guard case .edits(let edits) = cursor.drain() else { Issue.record("no edits"); return }
                await rig.manager.documentChanged(path: "f.x", change: .edits(edits, after: buffer.snapshot()))
            }
            #expect(await rig.manager.editLogCount(path: "f.x") == 0)
        }
    }

    @Test func editLogIsTrimmedOnceEveryServerCaughtUp() async throws {
        try await Rig.run([main, lint], scripts: ["main": script([]), "lint": script([])]) { rig in
            let buffer = CodeBuffer("abc\n")
            let cursor = buffer.makeEditCursor()
            await rig.manager.documentOpened(path: "f.x", snapshot: buffer.snapshot())
            for _ in 0..<100 {
                buffer.replace(0..<0, with: "z", origin: .typing)
                guard case .edits(let edits) = cursor.drain() else { Issue.record("no edits"); return }
                await rig.manager.documentChanged(path: "f.x", change: .edits(edits, after: buffer.snapshot()))
            }
            #expect(await waitUntil { await rig.manager.editLogCount(path: "f.x") ?? 99 < 20 })
        }
    }

    @Test func linterStopsWhenNoPathListsIt() async throws {
        try await Rig.run([main, lint]) { rig in
            await rig.manager.documentOpened(path: "a.x", snapshot: snap("x\n"))
            await rig.manager.documentOpened(path: "b.x", snapshot: snap("x\n"))
            #expect(await waitUntil { rig.openedURIs("lint").count == 2 })
            await rig.manager.documentClosed(path: "a.x")
            try await Task.sleep(for: .milliseconds(200))
            #expect(!rig.methods("lint").contains("shutdown"), "still listed by b.x")
            await rig.manager.documentClosed(path: "b.x")
            #expect(await waitUntil { rig.methods("lint").suffix(2) == ["shutdown", "exit"] })
            #expect(!rig.methods("main").contains("shutdown"))
            await rig.manager.documentOpened(path: "c.x", snapshot: snap("x\n"))
            #expect(await waitUntil { rig.launches.count("lint") == 2 && rig.openedURIs("lint").count == 3 })
            #expect(rig.launches.overlaps == 0)
        }
    }

    @Test func probeAnswersAreCachedUntilReload() async throws {
        let eslint = Rig.linter("eslint", ext: "ts", requires: ["eslint.config.*"])
        let tsMain = Rig.config("ts", ext: "ts")
        let present = Flag()
        let probe = ConfigProbe(exists: { _ in present.value })
        try await Rig.run([tsMain, eslint], probe: probe) { rig in
            await rig.manager.documentOpened(path: "a.ts", snapshot: snap("x\n"))
            #expect(await waitUntil { rig.openedURIs("ts").count == 1 })
            present.value = true
            await rig.manager.documentOpened(path: "b.ts", snapshot: snap("x\n"))   // same folder: cached "no"
            try await Task.sleep(for: .milliseconds(150))
            #expect(rig.launches.count("eslint") == 0)
            await rig.manager.reload(registry: rig.registry)   // cache cleared: both files gain the linter
            #expect(await waitUntil { rig.openedURIs("eslint").count == 2 })
            // And the config going away closes the linter on its files, without restarting anything else.
            present.value = false
            await rig.manager.reload(registry: rig.registry)
            #expect(await waitUntil { rig.methods("eslint").filter { $0 == "textDocument/didClose" }.count == 2 })
            #expect(rig.launches.count("ts") == 1)
        }
    }

    @Test func reopenUnderNewExtensionMovesLinters() async throws {
        let py = Rig.config("py", ext: "py"), ts = Rig.config("ts", ext: "ts")
        let ruff = Rig.linter("ruff", ext: "py"), eslint = Rig.linter("eslint", ext: "ts")
        try await Rig.run([py, ts, ruff, eslint]) { rig in
            await rig.manager.documentOpened(path: "a.py", snapshot: snap("x\n"))
            #expect(await waitUntil { rig.openedURIs("ruff").count == 1 && rig.openedURIs("py").count == 1 })
            await rig.manager.documentClosed(path: "a.py")
            await rig.manager.documentOpened(path: "a.ts", snapshot: snap("x\n"))
            #expect(await waitUntil { rig.methods("ruff").contains("textDocument/didClose") })
            #expect(await waitUntil { rig.openedURIs("eslint").count == 1 && rig.openedURIs("ts").count == 1 })
            #expect(rig.methods("py").contains("textDocument/didClose"))
        }
    }

    @Test func absentLinterStartsNothing() async throws {
        let ghost = Rig.linter("ghost", ext: "x", command: "/nonexistent/alloy-no-such-linter")
        try await Rig.run([main, ghost]) { rig in
            let seen = Collector(rig.manager.results)
            await rig.manager.documentOpened(path: "a.x", snapshot: snap("x\n"))
            await rig.manager.documentOpened(path: "b.x", snapshot: snap("y\n"))
            #expect(await waitUntil { seen.states("Lint ghost").count == 1 })
            try await Task.sleep(for: .milliseconds(150))
            #expect(seen.states("Lint ghost") == [.notInstalled(command: "/nonexistent/alloy-no-such-linter")])
            #expect(rig.launches.count("ghost") == 0)
            #expect(rig.launches.count("main") == 1)
        }
    }
    // MARK: - Review fixes

    private func isFailed(_ s: ServerState) -> Bool { if case .failed = s { true } else { false } }

    @Test func notInstalledLinterCostsNoLogPerKeystroke() async throws {
        let ghost = Rig.linter("ghost", ext: "x", command: "/nonexistent/alloy-no-such-linter")
        try await Rig.run([main, ghost]) { rig in
            let typer = Typer(path: "f.x", text: "abc\n")
            await rig.manager.documentOpened(path: "f.x", snapshot: typer.buffer.snapshot())
            await typer.type(rig.manager, times: 100)
            #expect(await rig.manager.editLogCount(path: "f.x") == 0)
        }
    }

    @Test func saveTimePublishFromEveryLiveMemberTrimsTheLog() async throws {
        let saveOnly = #"{"capabilities":{"textDocumentSync":2},"publishOnSave":true,"diagnostics":[]}"#
        try await Rig.run([main, lint], scripts: ["main": saveOnly, "lint": saveOnly]) { rig in
            let typer = Typer(path: "f.x", text: "abc\n")
            await rig.manager.documentOpened(path: "f.x", snapshot: typer.buffer.snapshot())
            await typer.type(rig.manager, times: 600)
            let before = try #require(await rig.manager.editLogCount(path: "f.x"))
            #expect(before >= 600, "\(before)")
            await rig.manager.documentSaved(path: "f.x")
            #expect(await waitUntil { (await rig.manager.editLogCount(path: "f.x") ?? .max) < 100 })
        }
    }

    @Test func missingMainServerLeavesNoLogForASingleLinter() async throws {
        let ghost = Rig.config("ghost", ext: "x", command: "/nonexistent/alloy-no-such-main")
        try await Rig.run([ghost, lint]) { rig in
            let typer = Typer(path: "f.x", text: "abc\n")
            await rig.manager.documentOpened(path: "f.x", snapshot: typer.buffer.snapshot())
            await typer.type(rig.manager, times: 100)
            #expect(await rig.manager.editLogCount(path: "f.x") == 0)
        }
    }

    @Test func mainFailureKeepsLinterFindingsAndDropsMains() async throws {
        try await Rig.run([main, lint], scripts: [
            "main": script([diag(0, 0, "m", source: "main")], extra: #","crashAfter":3"#),
            "lint": script([diag(0, 1, "l", source: "lint")]),
        ]) { rig in
            let seen = Collector(rig.manager.results)
            let typer = Typer(path: "f.x", text: "abcd\n")
            await rig.manager.documentOpened(path: "f.x", snapshot: typer.buffer.snapshot())
            #expect(await waitUntil { lastDiagnostics(seen, "f.x")?.items.count == 2 })
            #expect(await waitUntil(.seconds(30)) { seen.states("Fake main").contains { isFailed($0) } })
            #expect(await waitUntil { lastDiagnostics(seen, "f.x")?.items.map(\.message) == ["l"] })
            await typer.type(rig.manager, times: 1)   // the linter publishes again
            #expect(await waitUntil { lastDiagnostics(seen, "f.x")?.version == Int(typer.buffer.snapshot().version) })
            #expect(lastDiagnostics(seen, "f.x")?.items.map(\.message) == ["l"])
        }
    }

    @Test func failedLinterIsNotRelaunchedUntilReload() async throws {
        try await Rig.run([main, lint], scripts: ["lint": #"{"exitOnInitializeFromLaunch":1}"#]) { rig in
            let seen = Collector(rig.manager.results)
            await rig.manager.documentOpened(path: "f.x", snapshot: snap("abcd\n"))
            #expect(await waitUntil(.seconds(30)) { seen.states("Lint lint").contains { isFailed($0) } })
            await rig.manager.documentClosed(path: "f.x")
            #expect(await waitUntil { let entryExists = await rig.manager.hasEntry(id: "lint"); let stops = await rig.manager.pendingStopCount(); return !entryExists && stops == 0 })
            let launched = rig.launches.count("lint")
            await rig.manager.documentOpened(path: "f.x", snapshot: snap("abcd\n"))
            try await Task.sleep(for: .milliseconds(300))
            #expect(rig.launches.count("lint") == launched)
            await rig.manager.reload(registry: rig.registry)
            #expect(await waitUntil { rig.launches.count("lint") > launched })
        }
    }

    @Test func effectiveLinterIDsAreReportedPerPath() async throws {
        let eslint = Rig.linter("eslint", ext: "ts", requires: ["eslint.config.*"])
        let tsMain = Rig.config("ts", ext: "ts")
        let probe = ConfigProbe(exists: { $0.path.hasSuffix("/web/eslint.config.js") })
        try await Rig.run([tsMain, eslint], probe: probe) { rig in
            let seen = Collector(rig.manager.results)
            await rig.manager.documentOpened(path: "scripts/tool.ts", snapshot: snap("x\n"))
            await rig.manager.documentOpened(path: "web/app.ts", snapshot: snap("x\n"))
            func ids(_ path: String) -> [String]? {
                seen.all.reversed().compactMap { r -> [String]? in
                    if case .linters(let p, let ids) = r, p == path { ids } else { nil }
                }.first
            }
            #expect(await waitUntil { ids("web/app.ts") == ["eslint"] })
            #expect(await waitUntil { ids("scripts/tool.ts") != nil })
            #expect(ids("scripts/tool.ts") == [])
        }
    }

    @Test func finishedStopsArePruned() async throws {
        try await Rig.run([main, lint]) { rig in
            for _ in 0..<3 {
                await rig.manager.documentOpened(path: "f.x", snapshot: snap("x\n"))
                #expect(await waitUntil { rig.openedURIs("lint").count >= 1 })
                await rig.manager.documentClosed(path: "f.x")
            }
            #expect(await waitUntil { await rig.manager.pendingStopCount() == 0 })
        }
    }

    @Test func unusedLinterStopsAfterTheIdleDelay() async throws {
        try await Rig.run([main, lint], linterIdleDelay: .milliseconds(600)) { rig in
            await rig.manager.documentOpened(path: "f.x", snapshot: snap("x\n"))
            #expect(await waitUntil { rig.openedURIs("lint").count == 1 })
            await rig.manager.documentClosed(path: "f.x")
            try await Task.sleep(for: .milliseconds(250))
            #expect(!rig.methods("lint").contains("shutdown"), "stopped before the delay")
            #expect(await waitUntil { rig.methods("lint").suffix(2) == ["shutdown", "exit"] })
        }
    }

    @Test func reopeningWithinTheIdleDelayKeepsTheLinter() async throws {
        try await Rig.run([main, lint], linterIdleDelay: .milliseconds(500)) { rig in
            await rig.manager.documentOpened(path: "f.x", snapshot: snap("x\n"))
            #expect(await waitUntil { rig.openedURIs("lint").count == 1 })
            await rig.manager.documentClosed(path: "f.x")
            await rig.manager.documentOpened(path: "g.x", snapshot: snap("x\n"))
            #expect(await waitUntil { rig.openedURIs("lint").count == 2 })
            try await Task.sleep(for: .milliseconds(900))
            #expect(!rig.methods("lint").contains("shutdown"))
            #expect(rig.launches.count("lint") == 1)
        }
    }

    @Test func linterWithoutLanguageIDsGetsTheRegistrysIDForThePath() async throws {
        var efm = Rig.linter("efm", ext: "x")
        efm.languageID = "plaintext"
        let ts = ServerConfig(id: "ts", name: "TS", languageID: "typescript", languageIDs: ["x": "typescriptreact"], extensions: ["x"],
                              command: fakeServerPath)
        try await Rig.run([ts, efm]) { rig in
            await rig.manager.documentOpened(path: "f.x", snapshot: snap("x\n"))
            #expect(await waitUntil { rig.openedURIs("efm").count == 1 })
            #expect(rig.openedLanguageIDs("efm") == ["typescriptreact"])
        }
    }

}

private final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false
    var value: Bool {
        get { lock.withLock { flag } }
        set { lock.withLock { flag = newValue } }
    }
}

@MainActor
private final class Typer {
    let path: String
    let buffer: CodeBuffer
    private let cursor: CodeEditCursor
    init(path: String, text: String) {
        self.path = path
        buffer = CodeBuffer(text)
        cursor = buffer.makeEditCursor()
    }
    func type(_ manager: LSPManager, times: Int) async {
        for _ in 0..<times {
            buffer.replace(0..<0, with: "z", origin: .typing)
            guard case .edits(let edits) = cursor.drain() else { Issue.record("no edits"); return }
            await manager.documentChanged(path: path, change: .edits(edits, after: buffer.snapshot()))
        }
    }
}
