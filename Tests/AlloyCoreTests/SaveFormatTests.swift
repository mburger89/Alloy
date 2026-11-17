@testable import AlloyCore
import Foundation
import MetalUICodeBuffer
import Testing

/// The `format:` save path and its hook: only deliberate saves run `formatBeforeSave`.
@MainActor @Suite struct SaveFormatTests {
    private func dirty(_ e: Env, _ name: String = "a.txt") async throws -> EditorDocument {
        e.write(name, "hello\n")
        await e.ws.open(name)
        let doc = try #require(e.ws.document(name))
        _ = doc.buffer.replace(0..<0, with: "x")
        return doc
    }

    private func countingHook(_ e: Env, append: String = "") -> Counter {
        let counter = Counter()
        e.ws.formatBeforeSave = { doc in
            counter.calls += 1
            if !append.isEmpty { _ = doc.buffer.replace(doc.buffer.snapshot().text.utf8.count..<doc.buffer.snapshot().text.utf8.count, with: append) }
        }
        return counter
    }

    @MainActor final class Counter { var calls = 0 }

    @Test func formatTrueCallsTheHookOnceBeforeTheWrite() async throws {
        let e = Env(); defer { e.cleanup() }
        _ = try await dirty(e)
        let hook = countingHook(e, append: "END\n")
        try await e.ws.save("a.txt", format: true)
        #expect(hook.calls == 1)
        #expect(e.read("a.txt") == "xhello\nEND\n")
        #expect(e.ws.writeCount == 1)
    }

    @Test func formatFalseNeverCallsTheHook() async throws {
        let e = Env(); defer { e.cleanup() }
        _ = try await dirty(e)
        let hook = countingHook(e)
        try await e.ws.save("a.txt")
        #expect(hook.calls == 0)
        #expect(e.read("a.txt") == "xhello\n")
    }

    @Test func autosaveNeverFormats() async throws {
        let e = Env(); defer { e.cleanup() }
        let doc = try await dirty(e)
        let hook = countingHook(e)
        await waitUntil("timer armed") { e.clock.pendingSleepers == 1 }
        e.clock.advance(by: 1.1)
        await waitUntil("autosave") { !doc.isDirty }
        #expect(hook.calls == 0)
    }

    @Test func cleanDocumentNeverCallsTheHook() async throws {
        let e = Env(); defer { e.cleanup() }
        e.write("a.txt", "hello\n")
        await e.ws.open("a.txt")
        let hook = countingHook(e)
        try await e.ws.save("a.txt", format: true)
        #expect(hook.calls == 0)
        #expect(e.ws.writeCount == 0)
    }

    @Test func aSuspendedHookSerialisesASecondSave() async throws {
        let e = Env(); defer { e.cleanup() }
        let doc = try await dirty(e)
        let hook = Counter()
        var release: CheckedContinuation<Void, Never>?
        e.ws.formatBeforeSave = { _ in
            hook.calls += 1
            await withCheckedContinuation { release = $0 }
        }
        let first = Task { try await e.ws.save("a.txt", format: true) }
        await waitUntil("hook running") { release != nil }
        let second = Task { try await e.ws.save("a.txt", format: true) }
        for _ in 0..<50 { await Task.yield() }
        #expect(hook.calls == 1)
        #expect(e.ws.writeCount == 0)
        release?.resume(); release = nil
        try await first.value
        try await second.value
        #expect(hook.calls == 1)            // the second found the document clean
        #expect(e.ws.writeCount == 1)
        #expect(!doc.isDirty)
    }

    @Test func focusLeftAndCloseFormatButTabSwitchAndSaveAllDoNot() async throws {
        let e = Env(); defer { e.cleanup() }
        _ = try await dirty(e, "a.txt")
        let hook = countingHook(e)
        await e.ws.focusLeft("a.txt")
        #expect(hook.calls == 1)

        _ = try #require(e.ws.document("a.txt")).buffer.replace(0..<0, with: "y")
        await e.ws.close("a.txt")
        #expect(hook.calls == 2)

        _ = try await dirty(e, "b.txt")
        await e.ws.saveAll()
        #expect(hook.calls == 2)

        e.write("c.txt", "c")
        await e.ws.open("c.txt")
        _ = try #require(e.ws.document("c.txt")).buffer.replace(0..<0, with: "z")
        e.ws.activeTab = "c.txt"
        _ = try #require(e.ws.document("b.txt"))
        e.ws.activeTab = "b.txt"
        await e.ws.settle()
        #expect(hook.calls == 2)
        #expect(e.read("c.txt") == "zc")
    }

    @Test func saveActiveFormatsTheActiveTab() async throws {
        let e = Env(); defer { e.cleanup() }
        _ = try await dirty(e)
        e.ws.activeTab = "a.txt"
        let hook = countingHook(e)
        await e.ws.saveActive()
        #expect(hook.calls == 1)
        #expect(e.read("a.txt") == "xhello\n")
    }

    @Test func saveActiveWithNoTabDoesNothing() async {
        let e = Env(); defer { e.cleanup() }
        let hook = countingHook(e)
        await e.ws.saveActive()
        #expect(hook.calls == 0)
    }
}
