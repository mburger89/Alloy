import Foundation
import Testing
@testable import AlloyCore

@Suite struct FrameTimingDumpTests {
    @Test func roundTrips() throws {
        let frames = [
            FrameRecord(kind: "key", queueNs: 10, buildNs: 2_000, encodeNs: 300, inputToCommitNs: 5_000, inputToPresentedNs: 9_000),
            FrameRecord(kind: nil, queueNs: nil, buildNs: 1, encodeNs: 2, inputToCommitNs: nil, inputToPresentedNs: nil),
        ]
        let data = try FrameTimingDump.encode(frames)
        #expect(String(decoding: data, as: UTF8.self).contains("\"schemaVersion\":1"))
        #expect(try FrameTimingDump.decode(data) == frames)
    }
}
