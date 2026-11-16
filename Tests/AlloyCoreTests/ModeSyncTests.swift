@testable import AlloyCore
import AlloyTestSupport
import Foundation
import MetalUICodeBuffer
import Testing

@MainActor @Suite struct ModeSyncTests {
    private func group(_ e: Env) -> PaneID { .group(e.ws.codeLayout.focusedGroupID) }

    @Test func switchToChatShowsTheFocusedGroupsFile() async {
        let e = Env(); defer { e.cleanup() }
        e.write("x", "x\n"); e.write("y", "y\n")
        await e.ws.open("x", in: .chat)
        e.ws.setMode(.code)
        await e.ws.open("y", in: group(e))
        e.ws.setMode(.chat)
        #expect(e.ws.activeTab == "y")
        #expect(e.ws.tabs == ["x", "y"])
        #expect(e.ws.fileTreeActive == false)
    }

    @Test func existingChatTabIsNotDuplicatedOrMoved() async {
        let e = Env(); defer { e.cleanup() }
        e.write("x", "x\n"); e.write("y", "y\n")
        await e.ws.open("x", in: .chat)
        await e.ws.open("y", in: .chat)
        await e.ws.open("x", in: group(e))
        e.ws.setMode(.code)
        e.ws.setMode(.chat)
        #expect(e.ws.tabs == ["x", "y"])
        #expect(e.ws.activeTab == "x")
    }

    @Test func otherGroupsFilesStayOutOfChatTabs() async {
        let e = Env(); defer { e.cleanup() }
        e.write("a", "a\n"); e.write("b", "b\n"); e.write("c", "c\n")
        let first = group(e)
        await e.ws.open("a", in: first)
        await e.ws.open("c", in: first)
        e.ws.setMode(.code)
        e.ws.setMode(.chat)
        #expect(e.ws.tabs == ["c"])
        #expect(e.ws.activeTab == "c")
    }

    @Test func emptyFocusedGroupLeavesChatAsIs() async {
        let e = Env(); defer { e.cleanup() }
        e.write("x", "x\n")
        await e.ws.open("x", in: .chat)
        e.ws.setMode(.code)
        e.ws.setMode(.chat)
        #expect(e.ws.tabs == ["x"])
        #expect(e.ws.activeTab == "x")
    }

    @Test func firstSwitchToCodeSeedsTheEmptyGroup() async {
        let e = Env(); defer { e.cleanup() }
        e.write("x", "x\n")
        await e.ws.open("x", in: .chat)
        e.ws.setMode(.code)
        #expect(e.ws.tabs(in: group(e)) == ["x"])
        #expect(e.ws.activeTab(in: group(e)) == "x")
        #expect(!e.ws.fileTreeActive, "no tree view is shown yet")
    }

    @Test func switchToChatDoesNotSaveChatsPreviousTab() async throws {
        let e = Env(); defer { e.cleanup() }
        e.write("x", "x\n"); e.write("y", "y\n")
        await e.ws.open("x", in: .chat)
        let x = try #require(e.ws.document("x"))
        _ = x.buffer.replace(0..<0, with: "typed ")
        e.ws.mode = .code      // already in Code mode with a group holding only y (no seeding of x)
        await e.ws.open("y", in: group(e))
        let writes = e.ws.writeCount
        e.ws.setMode(.chat)
        await e.ws.settle()
        #expect(e.ws.activeTab == "y")
        #expect(e.ws.writeCount == writes)
        #expect(x.isDirty)
        #expect(e.read("x") == "x\n")
    }

    @Test func switchesDoNotSaveReadOrReopen() async throws {
        let e = Env(); defer { e.cleanup() }
        e.write("x", "x\n"); e.write("y", "y\n")
        await e.ws.open("x", in: .chat)
        e.ws.setMode(.code)
        await e.ws.open("y", in: group(e))
        e.ws.setMode(.chat)
        let x = try #require(e.ws.document("x")), y = try #require(e.ws.document("y"))
        _ = x.buffer.replace(0..<0, with: "typed ")
        _ = y.buffer.replace(0..<0, with: "more ")
        let writes = e.ws.writeCount, reads = e.ws.outsideReadCount
        let xv = x.buffer.version, yv = y.buffer.version
        e.ws.setMode(.code)
        e.ws.setMode(.chat)
        e.ws.setMode(.code)
        await e.ws.settle()
        #expect(e.ws.writeCount == writes)
        #expect(e.ws.outsideReadCount == reads)
        #expect(e.ws.document("x") === x && e.ws.document("y") === y)
        #expect(x.buffer.version == xv && y.buffer.version == yv)
        #expect(x.buffer.canUndo && y.buffer.canUndo)
        #expect(x.isDirty && y.isDirty)
    }
}
