import Testing
import Foundation
@testable import BenchCore
@testable import BenchScenarios

@Suite struct TraceRunTests {
    static let message = "Instruments needs Developer Tools access to attach. Run once: sudo DevToolsSecurity -enable"

    @Test func devToolsDisabledRefuses() {
        let fail = Preflight.checkDevTools(status: "Developer mode is currently disabled.")
        #expect(fail?.code == 2)
        #expect(fail?.message == Self.message)
        #expect(Preflight.checkDevTools(status: "")?.code == 2)
        #expect(Preflight.checkDevTools(status: "Developer mode is currently enabled.") == nil)
    }

    @Test func tracedResultIsRefusedByPublisher() throws {
        var r = PublishTests.complete()
        r.traced = true; r.traceKind = .time
        do { _ = try Publisher.prepare(r, scrubber: PublishTests.scrubber, allowPartial: true); Issue.record("no throw") }
        catch { #expect(error == .traced); #expect(error.description.contains("--trace")) }
        let back = try JSONDecoder().decode(RunResult.self, from: JSONEncoder().encode(r))
        #expect(back.traced); #expect(back.traceKind == .time)
    }

    @Test func oldResultsDecodeUntraced() throws {
        let data = try JSONEncoder().encode(PublishTests.complete())
        #expect(!String(decoding: data, as: UTF8.self).contains("traced"))
        let back = try JSONDecoder().decode(RunResult.self, from: data)
        #expect(!back.traced); #expect(back.traceKind == nil)
    }

    @Test func onlyFirstRunIsTraced() {
        let s = TraceSession(kind: .time, directory: "/home/tester/traces/x")
        #expect(s.shouldTrace(app: "alloy", metric: .memory))
        #expect(!s.shouldTrace(app: "alloy", metric: .memory))
        #expect(s.shouldTrace(app: "zed", metric: .memory))
        #expect(s.shouldTrace(app: "alloy", metric: .startup))
        #expect(s.path(app: "alloy", metric: .memory) == "/home/tester/traces/x/alloy-memory.trace")
    }

    @Test func noteText() {
        #expect(TraceSession.unavailableNote(app: "Zed", metric: .memory, reason: "denied") == "trace unavailable for Zed memory: denied")
        let s = TraceSession(kind: .allocations, directory: "/home/tester/t")
        #expect(s.savedNote(app: "alloy", metric: .memory) ==
                "trace: alloy-memory.trace (allocations; attached after launch, so launch work before the attach is missing)")
        #expect(s.savedNote(app: "alloy", metric: .memory, partialReason: "x").hasSuffix("; may be partial: x"))
        s.addNote("n", app: "alloy", metric: .memory)
        #expect(s.notes(app: "alloy", metric: .memory) == ["n"])
        #expect(s.notes(app: "zed", metric: .memory).isEmpty)
    }

    @Test func unsupportedNoteText() {
        #expect(TraceSession.unsupportedNote(app: "Zed", metric: .startup) ==
                "trace not supported for Zed startup: launch is measured from the first frame, before an attach could start")
    }

    @Test func markdownFlagsTracedRuns() {
        var r = PublishTests.complete()
        #expect(!Report.markdown(r).contains("Traced"))
        r.traced = true; r.traceKind = .gpu
        #expect(Report.markdown(r).contains("\n- Traced (gpu): timings include profiler overhead; not publishable\n"))
    }
}

@Suite struct IdleTraceNotesTests {
    @Test func notesFollowTheRequestedIdleMetric() {
        let cpu = Outcome.notMeasured("c"), mem = Outcome.notMeasured("m")
        let note = ["trace saved"]
        #expect(Runner.idleTraceMetric([.memoryIdle]) == .memoryIdle)
        #expect(Runner.idleTraceMetric([.memoryIdle, .idleCPU]) == .idleCPU)
        let memOnly = Runner.attachIdleNotes(cpu: cpu, memory: mem, notes: note, metrics: [.memoryIdle])
        #expect(memOnly.memory == mem.addingNotes(note)); #expect(memOnly.cpu == cpu)
        let both = Runner.attachIdleNotes(cpu: cpu, memory: mem, notes: note, metrics: [.idleCPU, .memoryIdle])
        #expect(both.cpu == cpu.addingNotes(note)); #expect(both.memory == mem)
    }
}
