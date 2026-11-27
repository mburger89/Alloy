@testable import AlloyCore
import Foundation
import MetalUICodeBuffer
import Testing

/// `Workspace.saveAs`: inside the project the tab is replaced in place; outside, the copy is written and the tab stays.
@MainActor @Suite struct SaveAsTests {
    @MainActor final class Counter { var calls = 0 }

    private func open3(_ e: Env) async throws {
        for name in ["a.txt", "b.txt", "c.txt"] { e.write(name, "hello\n"); await e.ws.open(name) }
        _ = try #require(e.ws.document("b.txt")).buffer.replace(0..<0, with: "x")
    }

    @Test func insideTheProjectReplacesTheTabAtItsIndexAndClosesTheOriginal() async throws {
        let e = Env(); defer { e.cleanup() }
        try await open3(e)
        try await e.ws.saveAs("b.txt", to: e.ws.projectRoot.appendingPathComponent("copy.txt"))
        #expect(e.ws.tabs == ["a.txt", "copy.txt", "c.txt"])
        #expect(e.ws.activeTab == "copy.txt")
        #expect(e.ws.document("b.txt") == nil)
        #expect(e.read("b.txt") == "xhello\n")
        #expect(e.read("copy.txt") == "xhello\n")
    }

    @Test func ownPathIsAPlainFormattedSave() async throws {
        let e = Env(); defer { e.cleanup() }
        try await open3(e)
        let formats = Counter()
        e.ws.formatBeforeSave = { _ in formats.calls += 1 }
        try await e.ws.saveAs("b.txt", to: e.ws.projectRoot.appendingPathComponent("b.txt"))
        #expect(e.ws.tabs == ["a.txt", "b.txt", "c.txt"] && formats.calls == 1)
        #expect(e.read("b.txt") == "xhello\n")
    }

    @Test func outsideTheProjectWritesTheCopyAndKeepsTheTab() async throws {
        let e = Env(); defer { e.cleanup() }
        try await open3(e)
        let elsewhere = FileManager.default.temporaryDirectory.appendingPathComponent("alloy-core-saveas-\(UUID().uuidString).txt")
        defer { try? FileManager.default.removeItem(at: elsewhere) }
        try await e.ws.saveAs("b.txt", to: elsewhere)
        #expect(try String(contentsOf: elsewhere, encoding: .utf8) == "xhello\n")
        #expect(e.ws.tabs == ["a.txt", "b.txt", "c.txt"])
        #expect(e.ws.document("b.txt") != nil)
    }
}
