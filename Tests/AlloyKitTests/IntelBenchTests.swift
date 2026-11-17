import AlloyCore
import AlloyLSP
@testable import AlloyKit
import AlloyTestSupport
import Foundation
import MetalUI
import MetalUITesting
import Testing

/// Keystroke-to-frame time of typing 50 identifier characters with completion on (a fast server, a slow one, a 5,000-item
/// reply) against the same file with no completion capability. Prints `INTELBENCH` lines; asserts only that the frame
/// requests stay within the guards. The labels never match the typed letters, so the popup stays closed and the full
/// request, decode and filter path still runs for every answer.
@MainActor
@Suite struct IntelBenchTests {
    private typealias Perf = CodeModePerformanceTests

    private struct Run { var millis: [Double]; var perFrame: [Int] }

    private func measure(script: String) async throws -> Run {
        let (intel, window, id) = try await IntelRig.guardRig(layout: .chat, script: script)
        try window.click(window.element(identifier: id))
        for _ in 0..<5 { window.tick(); await Task.yield() }
        // Warm up so the frame cost is the steady one.
        for _ in 0..<10 { window.typeText("a"); window.tick(); await Task.yield() }
        window.resetFrameWork()
        var millis: [Double] = []
        var perFrame: [Int] = []
        for _ in 0..<50 {
            let start = ContinuousClock.now
            window.typeText("a"); window.tick()
            let d = ContinuousClock.now - start
            millis.append(Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15)
            perFrame.append(window.frameWork.last?.elementRequests ?? 0)
            await Task.yield()
        }
        // Let the answers land and settle, then make sure nothing is stuck.
        await intel.idle(window, 0.3)
        withExtendedLifetime((intel, window)) {}
        return Run(millis: millis, perFrame: perFrame)
    }

    private func report(_ name: String, _ r: Run) {
        let sorted = r.millis.sorted()
        let mean = r.millis.reduce(0, +) / Double(r.millis.count)
        let p95 = sorted[min(sorted.count - 1, sorted.count * 95 / 100)]
        print(String(format: "INTELBENCH %@ keystroke-to-frame mean=%.2fms p95=%.2fms max=%.2fms maxRequests=%d",
                     name, mean, p95, sorted.last ?? 0, r.perFrame.max() ?? 0))
    }

    private static func items(_ n: Int) -> String {
        let list = (0..<n).map { #"{"label":"zq\#($0)"}"# }.joined(separator: ",")
        return #"{"result":{"isIncomplete":false,"items":[\#(list)]}}"#
    }

    @Test func typingFiftyCharactersWithCompletion() async throws {
        let base = try await measure(script: IntelRig.script(caps: #""referencesProvider":true"#))
        report("baseline(no completion)", base)
        let ceiling = ViewRerunTests.steadyFrameRequests + 1  // a closed overlay's known MetalUI gap
        let scenarios: [(String, String)] = [
            ("fast(0ms)", IntelRig.completionScript(completion: #"{"result":[{"label":"zq1"},{"label":"zq2"}]}"#)),
            ("slow(500ms)", IntelRig.completionScript(completion: #"{"result":[{"label":"zq1"}],"delayMs":500}"#)),
            ("big(5000 items)", IntelRig.completionScript(completion: Self.items(5000))),
        ]
        for (name, script) in scenarios {
            let run = try await measure(script: script)
            report(name, run)
            #expect(run.perFrame.allSatisfy { $0 <= ceiling }, "\(name) per-frame element requests \(run.perFrame)")
        }
        #expect(base.perFrame.allSatisfy { $0 <= ViewRerunTests.steadyFrameRequests }, "baseline \(base.perFrame)")
    }
}
