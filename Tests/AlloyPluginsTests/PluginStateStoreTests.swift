import AlloyCore
import AlloyTestSupport
import Foundation
import Testing
@testable import AlloyPlugins

@Suite("PluginStateStore", .serialized)
struct PluginStateStoreTests {
    private let t = PluginTestFolder()
    private var directory: URL { t.root.appendingPathComponent("plugin-state") }
    private func file(_ id: String) -> URL { directory.appendingPathComponent("\(id).json") }

    private func settle(_ clock: ManualClock) async {
        for _ in 0..<2000 where clock.pendingSleepers == 0 { await Task.yield() }
    }

    @Test func setThenGetRoundTrips() async throws {
        let store = PluginStateStore(directory: directory, limits: PluginLimits(), clock: ManualClock())
        try await store.set("dev.a.b", key: "last", value: .object(["n": .number(3), "s": .string("x")]))
        #expect(await store.get("dev.a.b", key: "last") == .object(["n": .number(3), "s": .string("x")]))
        #expect(await store.get("dev.a.b", key: "other") == nil)
        #expect(await store.get("dev.c.d", key: "last") == nil, "state is per plugin")
        await store.flush()
        // A fresh store (a restart) reads what was flushed.
        let again = PluginStateStore(directory: directory, limits: PluginLimits(), clock: ManualClock())
        #expect(await again.get("dev.a.b", key: "last") == .object(["n": .number(3), "s": .string("x")]))
    }

    @Test func nullDeletes() async throws {
        let store = PluginStateStore(directory: directory, limits: PluginLimits(), clock: ManualClock())
        try await store.set("dev.a.b", key: "k", value: .string("v"))
        try await store.set("dev.a.b", key: "k", value: nil)
        #expect(await store.get("dev.a.b", key: "k") == nil)
        try await store.set("dev.a.b", key: "j", value: .string("v"))
        try await store.set("dev.a.b", key: "j", value: .null)
        #expect(await store.get("dev.a.b", key: "j") == nil)
    }

    @Test func over64KiBIsRefused() async throws {
        let store = PluginStateStore(directory: directory, limits: PluginLimits(), clock: ManualClock())
        try await store.set("dev.a.b", key: "small", value: .string("ok"))
        await #expect(throws: PluginStateError.tooLarge) {
            try await store.set("dev.a.b", key: "big", value: .string(String(repeating: "x", count: 70_000)))
        }
        #expect(await store.get("dev.a.b", key: "big") == nil, "a refused set changes nothing")
        #expect(await store.get("dev.a.b", key: "small") == .string("ok"))
    }

    @Test func writesOnceAfterOneSecondDebounce() async throws {
        let clock = ManualClock()
        let store = PluginStateStore(directory: directory, limits: PluginLimits(), clock: clock)
        try await store.set("dev.a.b", key: "k", value: .number(1))
        clock.advance(by: 0.25)
        try await store.set("dev.a.b", key: "k", value: .number(2))
        clock.advance(by: 0.25)
        try await store.set("dev.a.b", key: "k", value: .number(3))
        await settle(clock)
        #expect(await store.writeCount == 0)
        #expect(!FileManager.default.fileExists(atPath: file("dev.a.b").path))
        clock.advance(by: 0.9)
        for _ in 0..<50 { await Task.yield() }
        #expect(await store.writeCount == 0, "the last change restarts the second")
        clock.advance(by: 0.2)
        for _ in 0..<5000 where await store.writeCount == 0 { await Task.yield() }
        #expect(await store.writeCount == 1)
        let text = try String(contentsOf: file("dev.a.b"), encoding: .utf8)
        #expect(JSONValue.parse(Data(text.utf8))?["k"] == .number(3))
    }

    @Test func flushWritesWhatIsStillWaiting() async throws {
        let store = PluginStateStore(directory: directory, limits: PluginLimits(), clock: ManualClock())
        try await store.set("dev.a.b", key: "k", value: .bool(true))
        await store.flush()
        #expect(await store.writeCount == 1)
        #expect(FileManager.default.fileExists(atPath: file("dev.a.b").path))
    }

    @Test func uiStateIsUntouched() async throws {
        let ui = t.root.appendingPathComponent("ui-state.json")
        try Data("{\"keep\":true}".utf8).write(to: ui)
        let store = PluginStateStore(directory: directory, limits: PluginLimits(), clock: ManualClock())
        try await store.set("dev.a.b", key: "k", value: .string("v"))
        await store.flush()
        #expect(try String(contentsOf: ui, encoding: .utf8) == "{\"keep\":true}")
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        #expect(names == ["dev.a.b.json"])
    }
}
