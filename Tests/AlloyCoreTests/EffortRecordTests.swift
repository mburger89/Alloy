import Testing
import Foundation
@testable import AlloyCore

@Suite struct EffortRecordTests {
    @Test func recordRoundTripsEffortAndOldRecordsLoad() throws {
        let id = UUID()
        let r = SessionRecord(id: id, name: "A", colorIndex: 1, hasConversation: true, effort: "max")
        let back = try JSONDecoder().decode(SessionRecord.self, from: JSONEncoder().encode(r))
        #expect(back.effort == "max")
        let old = #"{"id":"\#(id.uuidString)","name":"A","colorIndex":1,"model":"opus"}"#
        let loaded = try JSONDecoder().decode(SessionRecord.self, from: Data(old.utf8))
        #expect(loaded.effort == nil && loaded.model == "opus")
    }
}
