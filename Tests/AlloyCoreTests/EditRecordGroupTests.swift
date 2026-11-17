import Foundation
import Testing

@testable import AlloyCore

@Suite struct EditRecordGroupTests {
    @Test func oldFormatDecodesWithoutGroup() throws {
        let id = UUID()
        let json = """
        {"id":"\(id.uuidString)","author":{"user":{}},"path":"a.txt","date":1000,
         "hunks":[],"state":"live","toolUseID":"t1"}
        """
        let r = try JSONDecoder().decode(EditRecord.self, from: Data(json.utf8))
        #expect(r.group == nil)
        #expect(r.id == id)
        #expect(r.author == .user)
        #expect(r.path == "a.txt")
        #expect(r.toolUseID == "t1")
        #expect(r.state == .live)
        #expect(r.date == Date(timeIntervalSinceReferenceDate: 1000))
    }

    @Test func roundTripKeepsGroup() throws {
        let g = UUID()
        let r = EditRecord(id: UUID(), author: .user, path: "a", date: Date(timeIntervalSinceReferenceDate: 5),
                           toolUseID: nil, hunks: [], state: .kept, group: g)
        let back = try JSONDecoder().decode(EditRecord.self, from: JSONEncoder().encode(r))
        #expect(back == r)
        #expect(back.group == g)
    }

    @Test func applyFullTextStampsGroup() {
        var f = FileLedger(path: "a.txt", baseline: "one\n")
        let g = UUID()
        let rec = f.applyFullText(author: .user, newText: "two\n", toolUseID: nil, date: Date(), group: g)
        #expect(rec?.group == g)
        #expect(f.edits.last?.group == g)
        let plain = f.applyFullText(author: .user, newText: "three\n", toolUseID: nil, date: Date())
        #expect(plain?.group == nil)
    }

    @Test func ledgerRoundTripKeepsGroup() throws {
        var f = FileLedger(path: "a.txt", baseline: "one\n")
        let g = UUID()
        f.applyFullText(author: .user, newText: "two\n", toolUseID: nil, date: Date(), group: g)
        let back = try JSONDecoder().decode(FileLedger.self, from: JSONEncoder().encode(f))
        #expect(back.edits.map(\.group) == [g])
    }
}
