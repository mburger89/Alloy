@testable import AlloyCore
import AlloyTestSupport
import Foundation
import Testing

/// CSV and TSV open as a table in a Code group; everything else keeps its presentation.
@MainActor
@Suite struct CSVDefaultPresentationTests {
    private func rig(_ files: [String: String]) async -> (Env, PaneID) {
        let e = Env()
        e.ws.setMode(.code)
        for (name, text) in files { e.write(name, text) }
        return (e, .group(e.ws.codeLayout.focusedGroupID))
    }

    @Test func csvOpensAsTableInACodeGroup() async {
        let (e, pane) = await rig(["a.csv": "x,y\n1,2\n", "b.tsv": "x\ty\n1\t2\n"]); defer { e.cleanup() }
        await e.ws.open("a.csv", in: pane)
        await e.ws.open("b.tsv", in: pane)
        #expect(e.ws.presentation(of: "a.csv", in: pane) == .table)
        #expect(e.ws.presentation(of: "b.tsv", in: pane) == .table)
        #expect(e.ws.presentation(of: "UP.CSV", in: pane) == .table)
    }

    @Test func chatKeepsInlineForCsv() async {
        let (e, _) = await rig(["a.csv": "x,y\n"]); defer { e.cleanup() }
        #expect(e.ws.presentation(of: "a.csv", in: .chat) == .inline)
    }

    @Test func explicitPlainWinsAndSticksPerPaneAndPath() async {
        let (e, pane) = await rig(["a.csv": "x,y\n", "b.csv": "x,y\n"]); defer { e.cleanup() }
        await e.ws.open("a.csv", in: pane)
        await e.ws.open("b.csv", in: pane)
        e.ws.setPresentation(.plain, of: "a.csv", in: pane)
        #expect(e.ws.presentation(of: "a.csv", in: pane) == .plain)
        #expect(e.ws.presentation(of: "b.csv", in: pane) == .table)
        await e.ws.open("a.csv", in: pane)
        #expect(e.ws.presentation(of: "a.csv", in: pane) == .plain)
    }

    @Test func nonCsvStaysPlain() async {
        let (e, pane) = await rig(["a.swift": "let x = 1\n", "notes.txt": "hi\n"]); defer { e.cleanup() }
        await e.ws.open("a.swift", in: pane)
        #expect(e.ws.presentation(of: "a.swift", in: pane) == .plain)
        #expect(e.ws.presentation(of: "notes.txt", in: pane) == .plain)
    }

    @Test func diffModeOpenStillWins() async {
        let (e, pane) = await rig(["a.csv": "x,y\n1,2\n"]); defer { e.cleanup() }
        await e.ws.open("a.csv", mode: .inline, in: pane)
        #expect(e.ws.presentation(of: "a.csv", in: pane) == .inline)
    }
}
