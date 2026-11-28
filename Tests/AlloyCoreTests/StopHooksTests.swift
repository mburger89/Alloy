@testable import AlloyCore
import AlloyTestSupport
import Foundation
import Testing

@MainActor
private final class Counter {
    var value = 0
    var gate: CheckedContinuation<Void, Never>?
    var opened = false
}

@MainActor
struct StopHooksTests {
    private func makeWS() -> Workspace {
        let root = TempFiles.url("alloy-stop")
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let support = TempFiles.url("alloy-stop-s")
        return Workspace(projectRoot: root, appSupport: support, settings: AlloySettings(),
                         locate: { _ in URL(fileURLWithPath: "/fake/claude") },
                         makeTransport: { _ in ScriptedTransport() }, now: { Date() })
    }

    @Test func everyHookRunsOnceAndConcurrently() async {
        let ws = makeWS()
        let a = Counter(), b = Counter(), shared = Counter()
        // A waits until B has run; a serial run (A first) would deadlock.
        ws.addStopHook {
            if !shared.opened { await withCheckedContinuation { shared.gate = $0 } }
            a.value += 1
        }
        ws.addStopHook {
            b.value += 1
            shared.opened = true
            shared.gate?.resume()
            shared.gate = nil
        }
        await ws.stopAll()
        #expect(a.value == 1)
        #expect(b.value == 1)
    }

    @Test func stopAllTwiceRunsHooksOnce() async {
        let ws = makeWS()
        let c = Counter()
        ws.addStopHook { c.value += 1 }
        await ws.stopAll()
        await ws.stopAll()
        #expect(c.value == 1)
    }

    @Test func noHooksIsFine() async {
        let ws = makeWS()
        await ws.stopAll()
        #expect(ws.onStopHooks.isEmpty)
    }
}
