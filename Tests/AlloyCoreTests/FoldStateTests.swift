@testable import AlloyCore
import AlloyTestSupport
import Foundation
import MetalUICodeBuffer
import Testing

@MainActor @Suite struct FoldStateTests {
    private func twoPanes() async -> (Env, PaneID, PaneID) {
        let e = Env()
        e.ws.setMode(.code)
        e.write("a", (1...10).map { "line \($0)" }.joined(separator: "\n") + "\n")
        let g0 = e.ws.codeLayout.focusedGroupID
        await e.ws.open("a", in: .group(g0))
        e.ws.splitFocused(.horizontal)
        let g1 = e.ws.codeLayout.focusedGroupID
        return (e, .group(g0), .group(g1))
    }

    @Test func foldStateLivesWithSelectionState() async {
        let (e, p0, p1) = await twoPanes(); defer { e.cleanup() }
        _ = e.ws.selectionState(for: "a", in: p1)
        let f0 = e.ws.foldState(for: "a", in: p0)!
        let f1 = e.ws.foldState(for: "a", in: p1)!
        #expect(f0 !== f1)
        #expect(f0.buffer === e.ws.document("a")?.buffer)
        #expect(f0.selectionState === e.ws.selectionState(for: "a", in: p0))
        #expect(f1.selectionState === e.ws.selectionState(for: "a", in: p1))
        #expect(e.ws.foldState(for: "a", in: p0) === f0)
        #expect(e.ws.foldStates(for: "a").count == 2)
        #expect(e.ws.foldState(for: "nope", in: p0) == nil)
    }

    @Test func foldStateIsDroppedWithTheTab() async {
        let (e, p0, p1) = await twoPanes(); defer { e.cleanup() }
        _ = e.ws.selectionState(for: "a", in: p1)
        #expect(e.ws.foldState(for: "a", in: p1) != nil)
        await e.ws.close("a", in: p1)
        #expect(e.ws.foldState(for: "a", in: p1) == nil)
        #expect(e.ws.paneFolds[p1]?["a"] == nil)
        #expect(e.ws.foldState(for: "a", in: p0) != nil)
    }

    @Test func foldStateIsDroppedWithTheGroup() async {
        let (e, p0, p1) = await twoPanes(); defer { e.cleanup() }
        _ = e.ws.selectionState(for: "a", in: p1)
        weak var weakFold: CodeFoldState?
        do { weakFold = e.ws.foldState(for: "a", in: p1) }
        #expect(weakFold != nil)
        await e.ws.close("a", in: p1)
        #expect(e.ws.codeLayout.groups.count == 1)
        #expect(e.ws.paneFolds[p1] == nil)
        #expect(weakFold == nil)

        // installLayout replaces the groups' tabs, so their fold states go too.
        guard case .group(let id0) = p0, let layout = e.ws.currentUIState().layout else { Issue.record("layout"); return }
        let before = e.ws.foldState(for: "a", in: p0)
        e.ws.installLayout(layout, existing: ["a"])
        #expect(e.ws.paneFolds[p0] == nil)
        let after = e.ws.foldState(for: "a", in: .group(id0))
        #expect(after != nil && after !== before)
    }

    @Test func replacedDocumentGetsNewFoldState() async {
        let (e, p0, _) = await twoPanes(); defer { e.cleanup() }
        let old = e.ws.foldState(for: "a", in: p0)!
        let doc = e.ws.document("a")!
        let fresh = EditorDocument(path: "a", buffer: CodeBuffer(utf8: Array("x\ny\n".utf8)), language: nil,
                                   state: .editable, diskStamp: doc.diskStamp)
        e.ws.documents["a"] = fresh
        let new = e.ws.foldState(for: "a", in: p0)!
        #expect(new !== old)
        #expect(new.buffer === fresh.buffer)
        #expect(new.selectionState === e.ws.selectionState(for: "a", in: p0))
    }

    @Test func foldLinesRoundTripAsPairs() throws {
        let lines = FoldLines(2..<8)
        #expect(lines == FoldLines(start: 2, end: 7))
        #expect(lines.lines == 2..<8)
        let data = try JSONEncoder().encode(lines)
        #expect(String(decoding: data, as: UTF8.self) == "[2,7]")
        #expect(try JSONDecoder().decode(FoldLines.self, from: data) == lines)
        for bad in ["[3]", "[5,5]", "[-1,4]", "\"x\"", "[1,2,3]", "[4,2]"] {
            #expect(throws: DecodingError.self) { try JSONDecoder().decode(FoldLines.self, from: Data(bad.utf8)) }
        }
    }

    @Test func uiStateDecodesOldFilesWithoutFolds() throws {
        let state = try JSONDecoder().decode(UIState.self, from: Data(#"{"version":1,"mode":"code"}"#.utf8))
        #expect(state.folds.isEmpty)
        #expect(state.mode == .code)
    }

    @Test func uiStateKeepsVersionOne() throws {
        let folds = ["chat": ["a.swift": [FoldLines(start: 1, end: 4)]]]
        let state = UIState(mode: .code, folds: folds)
        #expect(state.version == 1)
        let data = try JSONEncoder().encode(state)
        let back = try JSONDecoder().decode(UIState.self, from: data)
        #expect(back.version == 1)
        #expect(back.folds == folds)
        #expect(UIState.currentVersion == 1)
    }

    @Test func malformedFoldsDecodeAsEmpty() throws {
        for bad in [#"{"version":1,"folds":{"chat":{"a":[[3]]}}}"#, #"{"version":1,"folds":5}"#,
                    #"{"version":1,"folds":{"chat":{"a":[[1,"x"]]}}}"#] {
            let state = try JSONDecoder().decode(UIState.self, from: Data(bad.utf8))
            #expect(state.folds.isEmpty)
            #expect(state.version == 1)
        }
    }
}
