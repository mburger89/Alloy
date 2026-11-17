import AlloyCore
import Foundation
import MetalUICodeBuffer
import Testing
@testable import AlloyLSP

@MainActor
struct TextEditsTests {
    private func snapshot(_ text: String) -> CodeSnapshot { CodeBuffer(text).snapshot() }

    private func edit(_ sl: Int, _ sc: Int, _ el: Int, _ ec: Int, _ text: String) -> JSONValue {
        .object(["range": .object(["start": .object(["line": .number(Double(sl)), "character": .number(Double(sc))]),
                                   "end": .object(["line": .number(Double(el)), "character": .number(Double(ec))])]),
                 "newText": .string(text)])
    }

    @Test func positionsPastTheEndClamp() throws {
        let s = snapshot("ab\ncd")
        let edits = try TextEditParsing.byteEdits([edit(0, 99, 9, 0, "X")], snapshot: s, encoding: .utf16)
        #expect(edits == [ByteEdit(range: 2..<5, text: "X")])
    }

    @Test func aPositionInsideASurrogatePairIsInvalid() {
        let s = snapshot("a😀b")
        #expect(throws: EditRejection.invalid("inside a surrogate pair")) {
            try TextEditParsing.byteEdits([edit(0, 2, 0, 3, "X")], snapshot: s, encoding: .utf16)
        }
        // Between the two scalars' boundaries it is fine: 3 is after the emoji.
        #expect((try? TextEditParsing.byteEdits([edit(0, 1, 0, 3, "X")], snapshot: s, encoding: .utf16)) == [ByteEdit(range: 1..<5, text: "X")])
    }

    @Test func aPositionInsideAUTF8SequenceIsInvalid() {
        let s = snapshot("a😀b")
        #expect(throws: EditRejection.self) {
            try TextEditParsing.byteEdits([edit(0, 2, 0, 3, "X")], snapshot: s, encoding: .utf8)
        }
        #expect((try? TextEditParsing.byteEdits([edit(0, 1, 0, 5, "X")], snapshot: s, encoding: .utf8)) == [ByteEdit(range: 1..<5, text: "X")])
    }

    @Test func utf32CountsScalars() throws {
        let s = snapshot("a😀b")
        let edits = try TextEditParsing.byteEdits([edit(0, 2, 0, 3, "X")], snapshot: s, encoding: .utf32)
        #expect(edits == [ByteEdit(range: 5..<6, text: "X")])
    }

    @Test func equalOffsetInsertsKeepArrayOrder() throws {
        let s = snapshot("abc")
        let edits = try TextEditParsing.byteEdits([edit(0, 1, 0, 1, "1"), edit(0, 0, 0, 0, "0"), edit(0, 1, 0, 1, "2")],
                                                  snapshot: s, encoding: .utf16)
        #expect(edits.map(\.text) == ["0", "1", "2"])
    }

    @Test func overlappingRangesAreRejected() {
        let s = snapshot("abcdef")
        #expect(throws: EditRejection.self) {
            try TextEditParsing.byteEdits([edit(0, 0, 0, 3, "X"), edit(0, 2, 0, 4, "Y")], snapshot: s, encoding: .utf16)
        }
        // Touching ranges do not overlap.
        #expect((try? TextEditParsing.byteEdits([edit(0, 0, 0, 3, "X"), edit(0, 3, 0, 4, "Y")], snapshot: s, encoding: .utf16))?.count == 2)
    }

    @Test func crlfDoesNotShiftOffsets() throws {
        let s = snapshot("ab\r\ncd\r\n")
        let edits = try TextEditParsing.byteEdits([edit(1, 0, 1, 2, "X"), edit(0, 1, 0, 50, "Y")], snapshot: s, encoding: .utf16)
        #expect(edits == [ByteEdit(range: 1..<2, text: "Y"), ByteEdit(range: 4..<6, text: "X")])
    }

    // MARK: WorkspaceEdit

    private let root = URL(fileURLWithPath: "/proj")
    private func uri(_ path: String) -> String { "file:///proj/\(path)" }
    private func texts(_ s: String = "abcdef") -> (String) -> CodeSnapshot? { { _ in CodeBuffer(s).snapshot() } }

    @Test func normalizesChangesAndDocumentChanges() throws {
        let one = edit(0, 0, 0, 1, "X")
        let changes: JSONValue = .object(["changes": .object([uri("b.rs"): .array([one]), uri("a.rs"): .array([one])])])
        let a = try WorkspaceEditParsing.normalize(changes, root: root, encoding: .utf16, snapshot: texts())
        #expect(a.map(\.path) == ["a.rs", "b.rs"])
        #expect(a.allSatisfy { $0.version == nil })

        let doc: JSONValue = .object(["documentChanges": .array([
            .object(["textDocument": .object(["uri": .string(uri("x.rs")), "version": .number(7)]), "edits": .array([one])]),
            .object(["textDocument": .object(["uri": .string(uri("y.rs")), "version": .null]), "edits": .array([one])]),
        ])])
        let b = try WorkspaceEditParsing.normalize(doc, root: root, encoding: .utf16, snapshot: texts())
        #expect(b == [FileEdits(path: "x.rs", version: 7, edits: [ByteEdit(range: 0..<1, text: "X")]),
                      FileEdits(path: "y.rs", version: nil, edits: [ByteEdit(range: 0..<1, text: "X")])])
    }

    @Test func fileOperationsAndOutsideURIsAreRefused() {
        let rename: JSONValue = .object(["documentChanges": .array([
            .object(["kind": .string("rename"), "oldUri": .string(uri("a.rs")), "newUri": .string(uri("b.rs"))])])])
        #expect(throws: EditRejection.resourceOperation) {
            try WorkspaceEditParsing.normalize(rename, root: root, encoding: .utf16, snapshot: texts())
        }
        let outside: JSONValue = .object(["changes": .object(["file:///elsewhere/a.rs": .array([edit(0, 0, 0, 1, "X")])])])
        #expect(throws: EditRejection.self) {
            try WorkspaceEditParsing.normalize(outside, root: root, encoding: .utf16, snapshot: texts())
        }
    }

    @Test func annotationsAreIgnored() throws {
        var annotated = edit(0, 0, 0, 1, "X")
        if case .object(var o) = annotated { o["annotationId"] = .string("a"); annotated = .object(o) }
        let value: JSONValue = .object([
            "changeAnnotations": .object(["a": .object(["label": .string("l"), "needsConfirmation": .bool(true)])]),
            "documentChanges": .array([.object(["textDocument": .object(["uri": .string(uri("a.rs")), "version": .null]),
                                                "edits": .array([annotated])])]),
        ])
        let out = try WorkspaceEditParsing.normalize(value, root: root, encoding: .utf16, snapshot: texts())
        #expect(out.first?.edits == [ByteEdit(range: 0..<1, text: "X")])
    }
}
