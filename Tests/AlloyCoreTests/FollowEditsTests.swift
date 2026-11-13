import AlloyTestSupport
import Foundation
import MetalUICodeBuffer
import Testing
@testable import AlloyCore

/// The right pane follows a session's edits: opens the file at the first changed line, without stealing the user's work.
@MainActor
@Suite struct FollowEditsTests {
    private let old = "one\ntwo\nthree\n", new = "one\nTWO\nthree\n"

    /// Delivers an Edit result from the session behind `transport`.
    private func edit(_ e: Env, _ transport: ScriptedTransport, _ name: String, id: String = "t1") async {
        let hunks = Patch.diff(old: TextLines(old).lines, new: TextLines(new).lines, context: 0)
        e.write(name, new)
        await transport.emit(.assistantBlock(messageID: "m" + id, block: .toolUse(id: id, name: "Edit", input: .object([:]))))
        await transport.emit(.toolResult(ToolResultMessage(toolUseID: id, isError: false, text: "ok",
                                                           result: .edit(filePath: e.url(name).path, originalFile: old, hunks: hunks))))
    }

    @Test func selectedSessionsEditOpensTheFileAtItsFirstChangedLine() async throws {
        let e = Env(); defer { e.cleanup() }
        e.write("a.txt", old)
        _ = await e.ws.newSession(name: "Ann")
        await edit(e, e.transports.all[0], "a.txt")
        await waitUntil("follow") { e.ws.activeTab == "a.txt" }
        await e.ws.settle()
        let doc = try #require(e.ws.document("a.txt"))
        #expect(e.ws.activeTab == "a.txt")
        #expect(doc.buffer.primarySelection.range == doc.buffer.snapshot().lineRange(1))
    }

    @Test func selectedSessionsEditReplacesAnActiveCleanTab() async throws {
        let e = Env(); defer { e.cleanup() }
        e.write("a.txt", old); e.write("b.txt", "x\n")
        await e.ws.open("b.txt")
        _ = await e.ws.newSession(name: "Ann")
        await edit(e, e.transports.all[0], "a.txt")
        await waitUntil("follow") { e.ws.activeTab == "a.txt" }
        await e.ws.settle()
        #expect(e.ws.activeTab == "a.txt")
    }

    @Test func otherSessionsEditKeepsAnActiveTabButFillsAnEmptyPane() async throws {
        let e = Env(); defer { e.cleanup() }
        e.write("a.txt", old); e.write("b.txt", "x\n")
        _ = await e.ws.newSession(name: "Ann")
        _ = await e.ws.newSession(name: "Bob")          // Ann stays selected
        await e.ws.open("b.txt")
        await edit(e, e.transports.all[1], "a.txt")
        await waitUntil("ledger") { e.ws.ledger.files["a.txt"] != nil }
        await e.ws.settle()
        #expect(e.ws.activeTab == "b.txt")
        // With no active tab, the same kind of edit opens.
        e.ws.closeActiveTab()
        await e.ws.settle()
        #expect(e.ws.activeTab == nil)
        await edit(e, e.transports.all[1], "a.txt", id: "t2")
        await waitUntil("follow") { e.ws.activeTab == "a.txt" }
        await e.ws.settle()
        #expect(e.ws.activeTab == "a.txt")
    }

    @Test func nothingOpensWhenFollowEditsIsOff() async throws {
        let e = Env(); defer { e.cleanup() }
        e.write("a.txt", old)
        var s = e.ws.settings
        s.followEdits = false
        try e.ws.updateSettings(s)
        _ = await e.ws.newSession(name: "Ann")
        await edit(e, e.transports.all[0], "a.txt")
        await waitUntil("ledger") { e.ws.ledger.files["a.txt"] != nil }
        await e.ws.settle()
        #expect(e.ws.activeTab == nil)
        #expect(e.ws.tabs.isEmpty)
    }

    @Test func nothingOpensWhileTheActiveDocumentIsDirty() async throws {
        let e = Env(); defer { e.cleanup() }
        e.write("a.txt", old); e.write("b.txt", "x\n")
        await e.ws.open("b.txt")
        let doc = try #require(e.ws.document("b.txt"))
        doc.buffer.replace(0..<0, with: "typed")
        #expect(doc.isDirty)
        _ = await e.ws.newSession(name: "Ann")
        await edit(e, e.transports.all[0], "a.txt")
        await waitUntil("ledger") { e.ws.ledger.files["a.txt"] != nil }
        await e.ws.settle()
        #expect(e.ws.activeTab == "b.txt")
        #expect(e.ws.tabs == ["b.txt"])
    }

    @Test func nothingOpensWhileTheCodePanelHasFocus() async throws {
        let e = Env(); defer { e.cleanup() }
        e.write("a.txt", old); e.write("b.txt", "x\n")
        await e.ws.open("b.txt")
        e.ws.codePanelFocused = true
        _ = await e.ws.newSession(name: "Ann")
        await edit(e, e.transports.all[0], "a.txt")
        await waitUntil("ledger") { e.ws.ledger.files["a.txt"] != nil }
        await e.ws.settle()
        #expect(e.ws.activeTab == "b.txt")
    }

    @Test func followEditsDefaultsOnAndSurvivesAnOldSettingsFile() throws {
        #expect(AlloySettings().followEdits)
        let decoded = try JSONDecoder().decode(AlloySettings.self, from: Data("{}".utf8))
        #expect(decoded.followEdits)
        var off = AlloySettings(); off.followEdits = false
        let back = try JSONDecoder().decode(AlloySettings.self, from: JSONEncoder().encode(off))
        #expect(!back.followEdits)
    }
}
