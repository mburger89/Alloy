@testable import AlloyCore
import Foundation
import Testing

@Suite struct OwnEditsTests {
    @Test func settingDefaultsOffAndDecodesOldFiles() throws {
        let s = AlloySettings()
        #expect(s.ownEditTint.enabled == false)
        #expect(s.ownEditTint.colorHex == nil)
        let empty = try JSONDecoder().decode(AlloySettings.self, from: Data("{}".utf8))
        #expect(empty.ownEditTint == OwnEditTint())
        let json = Data(##"{"ownEditTint":{"enabled":true,"colorHex":"#FF0000"}}"##.utf8)
        let on = try JSONDecoder().decode(AlloySettings.self, from: json)
        #expect(on.ownEditTint == OwnEditTint(enabled: true, colorHex: "#FF0000"))
        let again = try JSONDecoder().decode(AlloySettings.self, from: JSONEncoder().encode(on))
        #expect(again.ownEditTint == on.ownEditTint)
        let bad = try JSONDecoder().decode(AlloySettings.self, from: Data(#"{"ownEditTint":{"enabled":"x","colorHex":3}}"#.utf8))
        #expect(bad.ownEditTint == OwnEditTint())
    }

    @Test func identicalTextHasNoChanges() {
        #expect(OwnEdits.changedLines(saved: "a\nb\n", current: "a\nb\n").isEmpty)
        #expect(OwnEdits.changedBytes(saved: "a\nb\n", current: "a\nb\n").isEmpty)
    }

    @Test func typedLineIsOneRange() {
        let saved = "a\nb\nc\n", current = "a\nbX\nc\n"
        #expect(OwnEdits.changedLines(saved: saved, current: current) == [1..<2])
        let bytes = OwnEdits.changedBytes(saved: saved, current: current)
        #expect(bytes == [3..<4])
        #expect(Array(current.utf8)[3] == UInt8(ascii: "X"))
        #expect(bytes[0].lowerBound >= 2 && bytes[0].upperBound <= 5)
    }

    @Test func insertedLinesAndDeletionPoint() {
        #expect(OwnEdits.changedLines(saved: "a\nb\nc\n", current: "a\nx\ny\nb\nc\n") == [1..<3])
        #expect(OwnEdits.changedLines(saved: "a\nb\nc\n", current: "a\nc\n") == [1..<1])
    }

    @Test func undoBackToSavedClears() {
        let saved = "one\ntwo\n"
        var current = saved
        current.insert("Z", at: current.index(after: current.startIndex))
        #expect(!OwnEdits.changedLines(saved: saved, current: current).isEmpty)
        current.remove(at: current.index(after: current.startIndex))
        #expect(OwnEdits.changedLines(saved: saved, current: current).isEmpty)
        #expect(OwnEdits.changedBytes(saved: saved, current: current).isEmpty)
    }

    @Test func deletingWholeRowsLeavesNoSpan() {
        let saved = "id,n\n1,a\n2,b\n3,c\n"
        #expect(OwnEdits.changedBytes(saved: saved, current: "id,n\n1,a\n3,c\n").isEmpty, "middle row")
        #expect(OwnEdits.changedBytes(saved: saved, current: "id,n\n1,a\n2,b\n").isEmpty, "last row")
        #expect(OwnEdits.changedBytes(saved: saved, current: "id,n\n3,c\n").isEmpty, "several rows")
        #expect(OwnEdits.changedBytes(saved: "id,n\n1,a\n2,b", current: "id,n\n1,a").isEmpty, "last row, no final newline")
    }

    @Test func deletingRowKeepsOtherEdits() {
        let saved = "id,n\n1,a\n2,b\n3,c\n4,d\n"
        let bytes = OwnEdits.changedBytes(saved: saved, current: "id,n\n1,a\n3,c\n4,dX\n")
        #expect(bytes == [16..<17])
    }

    @Test func insertedRowIsOneSpan() {
        let bytes = OwnEdits.changedBytes(saved: "id,n\n1,a\n2,b\n", current: "id,n\n1,a\nx,y\n2,b\n")
        #expect(bytes == [9..<13])
    }
}
