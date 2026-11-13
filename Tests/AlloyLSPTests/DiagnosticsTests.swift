import AlloyCore
import AlloyLSPTestSupport
import Foundation
import MetalUICodeBuffer
import Testing
@testable import AlloyLSP

@MainActor
struct DiagnosticsTests {
    private func raw(_ line: Int, _ from: Int, _ to: Int, severity: Int? = 1, message: String = "m", source: String? = nil) -> JSONValue {
        var o: [String: JSONValue] = [
            "range": .object(["start": .object(["line": .number(Double(line)), "character": .number(Double(from))]),
                              "end": .object(["line": .number(Double(line)), "character": .number(Double(to))])]),
            "message": .string(message),
        ]
        if let severity { o["severity"] = .number(Double(severity)) }
        if let source { o["source"] = .string(source) }
        return .object(o)
    }

    /// A sync whose server never starts (the launcher says it is not installed), so nothing is sent.
    private func idleSync() async -> DocumentSync {
        let config = ServerConfig(id: "none", name: "None", languageID: "x", command: "none")
        let server = LanguageServer(config: config, root: FileManager.default.temporaryDirectory,
                                    launcher: { throw ServerProcessError.notInstalled(command: "none") })
        await server.start()
        return DocumentSync(server: server)
    }

    @Test func diagnosticRangeOnEmojiLine() {
        // "a" + emoji (4 bytes, 2 UTF-16 units) + "bc": UTF-16 characters 3..<4 are "b", bytes 5..<6.
        let snapshot = CodeBuffer("a😀bc\n").snapshot()
        let items = DiagnosticMapping.convert([raw(0, 3, 4, severity: 2, message: "boom", source: "rustc")], in: snapshot, encoding: .utf16)
        #expect(items == [LSPDiagnostic(range: 5..<6, severity: .warning, message: "boom", source: "rustc")])
        // The same bytes through the UTF-8 encoding are character 5.
        let utf8 = DiagnosticMapping.convert([raw(0, 5, 6)], in: snapshot, encoding: .utf8)
        #expect(utf8.first?.range == 5..<6)
        // A missing severity is an error; items come out sorted by start.
        let two = DiagnosticMapping.convert([raw(0, 4, 5, severity: nil), raw(0, 0, 1)], in: snapshot, encoding: .utf16)
        #expect(two.map(\.range) == [0..<1, 6..<7])
        #expect(two.last?.severity == .error)
    }

    @Test func emptyRangesAreWidenedToACharacter() {
        let snapshot = CodeBuffer("x😀\nyz").snapshot()
        // At the emoji: its 4 bytes. At the end of the line: the emoji before. On an empty last position: stays empty.
        #expect(DiagnosticMapping.convert([raw(0, 1, 1)], in: snapshot, encoding: .utf16).first?.range == 1..<5)
        #expect(DiagnosticMapping.convert([raw(0, 3, 3)], in: snapshot, encoding: .utf16).first?.range == 1..<5)
        #expect(DiagnosticMapping.convert([raw(1, 0, 0)], in: snapshot, encoding: .utf16).first?.range == 6..<7)
    }

    @Test func staleDiagnosticsAreMappedOrDropped() async throws {
        let sync = await idleSync()
        let uri = URL(string: "file:///tmp/stale.txt")!
        let buffer = CodeBuffer("fn a() {}\n")
        let cursor = buffer.makeEditCursor()
        await sync.open(uri: uri, languageID: "x", snapshot: buffer.snapshot())
        let first = Int(buffer.version)
        var snapshots = [buffer.snapshot()]
        // Eight ASCII inserts, then two multi-byte ones in front of everything: after those, the same UTF-16 range
        // is other bytes than it was at the kept version.
        for i in 0..<10 {
            buffer.replace(0..<0, with: i < 8 ? "x" : "\u{e9}", origin: .typing)
            guard case .edits(let edits) = cursor.drain() else { Issue.record("expected edits"); return }
            await sync.apply(uri: uri, change: .edits(edits, after: buffer.snapshot()))
            snapshots.append(buffer.snapshot())
        }
        let now = buffer.snapshot()
        let keptSnapshot = snapshots[snapshots.count - 3]
        let kept = Int(keptSnapshot.version)
        let items = await DiagnosticMapping.map([raw(0, 3, 4)], version: kept, sync: sync, uri: uri, current: now)
        let against = { (s: CodeSnapshot) in DiagnosticMapping.convert([self.raw(0, 3, 4)], in: s, encoding: .utf16).first?.range }
        #expect(items?.first?.range == against(keptSnapshot))
        #expect(against(keptSnapshot) != against(now), "the test must tell the two snapshots apart")
        #expect(items?.first?.range != against(now))
        // One whose version fell out of the last 8 sends is dropped.
        #expect(await DiagnosticMapping.map([raw(0, 0, 1)], version: first, sync: sync, uri: uri, current: now) == nil)
        // Without a version the current text is used.
        let unversioned = await DiagnosticMapping.map([raw(0, 3, 4)], version: nil, sync: sync, uri: uri, current: now)
        #expect(unversioned?.first?.range == against(now))
        // A document the sync does not know is dropped too.
        #expect(await DiagnosticMapping.map([], version: kept, sync: sync, uri: URL(string: "file:///tmp/other")!, current: now) == nil)
    }

    @Test func storeCountsChangeOnlyWhenACountChanges() {
        let store = DiagnosticStore()
        let error = LSPDiagnostic(range: 0..<1, severity: .error, message: "e")
        let hint = LSPDiagnostic(range: 0..<1, severity: .hint, message: "h")
        store.set(path: "a.rs", version: 1, items: [error, hint])
        #expect(store.counts.byPath["a.rs"]?.errors == 1)
        #expect(store.counts.byPath["a.rs"]?.warnings == 0)
        store.set(path: "a.rs", version: 2, items: [error])
        #expect(store.entry(for: "a.rs")?.version == 2)
        store.remove(path: "a.rs")
        #expect(store.counts.byPath["a.rs"] == nil)
        #expect(store.entry(for: "a.rs") == nil)
    }
}


@MainActor
@Suite
struct DiagnosticsManagerTests {
    private func manager(script: String) -> (LSPManager, URL) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("alloy-diag-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let launcher = ServerLauncher { _, resolved, root in
            var env = ProcessInfo.processInfo.environment
            env["FAKE_LSP_SCRIPT"] = script
            return try ServerProcess(executable: resolved, arguments: [], environment: env, currentDirectory: root)
        }
        let config = ServerConfig(id: "fake", name: "Fake", languageID: "x", extensions: ["x"], command: fakeServerPath)
        return (LSPManager(root: dir, registry: ServerRegistry(builtIn: [config]),
                           locator: ServerLocator(loginPATH: { nil }, xcrunFind: { _ in nil }), launcher: launcher), dir)
    }

    /// The first `.diagnostics` result, or nil after 10 s.
    private func firstDiagnostics(_ manager: LSPManager) async -> (path: String, version: Int?, items: [LSPDiagnostic])? {
        await withTaskGroup(of: (String, Int?, [LSPDiagnostic])?.self) { group in
            group.addTask {
                for await result in manager.results {
                    if case .diagnostics(let path, let version, let items) = result { return (path, version, items) }
                }
                return nil
            }
            group.addTask { try? await Task.sleep(for: .seconds(10)); return nil }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first.map { (path: $0.0, version: $0.1, items: $0.2) }
        }
    }

    private static let item = #"{"range":{"start":{"line":0,"character":3},"end":{"line":0,"character":4}},"severity":2,"message":"w","source":"fake"}"#

    @Test func pushedDiagnosticsReachResultsWithTheirVersion() async throws {
        let (manager, dir) = manager(script: #"{"capabilities":{"textDocumentSync":2},"diagnostics":[\#(Self.item)]}"#)
        defer { try? FileManager.default.removeItem(at: dir) }
        let snapshot = CodeBuffer("a😀bc\n").snapshot()
        await manager.documentOpened(path: "f.x", snapshot: snapshot)
        let got = await firstDiagnostics(manager)
        await manager.shutdownAll()
        #expect(got?.path == "f.x")
        #expect(got?.version == Int(snapshot.version))
        #expect(got?.items == [LSPDiagnostic(range: 5..<6, severity: .warning, message: "w", source: "fake")])
    }

    @Test func pullDiagnosticsAreUsedWhenTheServerDoesNotPush() async throws {
        let (manager, dir) = manager(script:
            #"{"capabilities":{"textDocumentSync":2,"diagnosticProvider":{"interFileDependencies":false,"workspaceDiagnostics":false}},"pullDiagnostics":[\#(Self.item)]}"#)
        defer { try? FileManager.default.removeItem(at: dir) }
        let snapshot = CodeBuffer("a😀bc\n").snapshot()
        await manager.documentOpened(path: "f.x", snapshot: snapshot)
        let got = await firstDiagnostics(manager)
        await manager.shutdownAll()
        #expect(got?.items.first?.range == 5..<6)
        #expect(got?.version == Int(snapshot.version))
    }

    @Test func serverWithoutPullCapabilityIsNeverAsked() async throws {
        let (manager, dir) = manager(script: #"{"capabilities":{"textDocumentSync":2},"pullDiagnostics":[\#(Self.item)]}"#)
        defer { try? FileManager.default.removeItem(at: dir) }
        await manager.documentOpened(path: "f.x", snapshot: CodeBuffer("abc\n").snapshot())
        let got = await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                for await result in manager.results { if case .diagnostics = result { return true } }
                return false
            }
            group.addTask { try? await Task.sleep(for: .seconds(1.5)); return false }
            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }
        await manager.shutdownAll()
        #expect(!got)
    }
}
