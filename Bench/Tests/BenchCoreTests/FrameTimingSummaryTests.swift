import Testing
import Foundation
@testable import BenchCore

@Suite struct FrameTimingSummaryTests {
    private func json(_ frames: [String]) -> Data {
        Data(#"{"schemaVersion":1,"frames":[\#(frames.joined(separator: ","))]}"#.utf8)
    }

    @Test func splitsByKind() {
        let keys = [2_000_000, 3_000_000, 4_000_000].map { #"{"kind":"key","buildNs":\#($0),"encodeNs":600000,"inputToPresentedNs":9800000}"# }
        let idle = [#"{"buildNs":1000000,"encodeNs":500000}"#]
        let notes = FrameTimingSummary.notes(from: json(keys + idle))
        #expect(notes.count == 2)
        #expect(notes[0].contains("key, 3 frames"))
        #expect(notes[0].contains("build 3.0"))
        #expect(notes[0].contains("input→present 9.8"))
        #expect(notes[1].contains("no input, 1 frames"))
        #expect(!notes[1].contains("queue"))
    }

    @Test func garbageGivesNoNotes() {
        #expect(FrameTimingSummary.notes(from: Data("x".utf8)) == [])
        #expect(FrameTimingSummary.notes(from: Data(#"{"schemaVersion":1}"#.utf8)) == [])
    }

    @Test func evenCountMedianAveragesTheMiddlePair() {
        let frames = [1_000_000, 2_000_000, 4_000_000, 9_000_000].map { #"{"kind":"text","buildNs":\#($0),"encodeNs":0}"# }
        let notes = FrameTimingSummary.notes(from: json(frames))
        #expect(notes.count == 1)
        #expect(notes[0].contains("build 3.0"))
        #expect(notes[0].hasPrefix(FrameTimingSummary.notePrefix))
    }
}
