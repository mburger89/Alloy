@testable import AlloyCore
import AlloyTestSupport
import Foundation
import MetalUICodeBuffer
import Observation
import Testing

@MainActor @Suite struct DocumentLifetimeTests {
    private func group(_ e: Env) -> PaneID { .group(e.ws.codeLayout.focusedGroupID) }

    @Test func oneDocumentForAllHolders() async throws {
        let e = Env(); defer { e.cleanup() }
        e.write("a.swift", "one\n")
        let g = group(e)
        await e.ws.open("a.swift", in: .chat)
        await e.ws.open("a.swift", in: g)
        let a = try #require(e.ws.document("a.swift"))
        #expect(e.ws.document("a.swift") === a)
        #expect(e.ws.tabs(in: .chat) == ["a.swift"])
        #expect(e.ws.tabs(in: g) == ["a.swift"])
    }

    @Test func documentLivesWhileAnyListHoldsIt() async throws {
        let e = Env(); defer { e.cleanup() }
        e.write("a.swift", "one\n")
        let g = group(e)
        await e.ws.open("a.swift", in: .chat)
        await e.ws.open("a.swift", in: g)
        await e.ws.close("a.swift", in: .chat)
        #expect(e.ws.document("a.swift") != nil)
        #expect(e.ws.holds("a.swift"))
        await e.ws.close("a.swift", in: g)
        #expect(e.ws.document("a.swift") == nil)
        #expect(!e.ws.holds("a.swift"))
    }

    @Test func closingOneHolderSavesButKeepsTheDocument() async throws {
        let e = Env(); defer { e.cleanup() }
        e.write("a.swift", "one\n")
        let g = group(e)
        await e.ws.open("a.swift", in: .chat)
        await e.ws.open("a.swift", in: g)
        let doc = try #require(e.ws.document("a.swift"))
        _ = doc.buffer.replace(0..<0, with: "typed ")
        await e.ws.close("a.swift", in: .chat)
        #expect(e.read("a.swift") == "typed one\n")
        #expect(e.ws.document("a.swift") === doc)
        #expect(!doc.isDirty)
        #expect(doc.buffer.canUndo)
    }

    @Test func groupOpenLeavesChatTabsAlone() async throws {
        let e = Env(); defer { e.cleanup() }
        e.write("b", "b\n")
        let g = group(e)
        await e.ws.open("b", in: g)
        #expect(e.ws.tabs == [])
        #expect(e.ws.tabs(in: g) == ["b"])
        #expect(e.ws.activeTab(in: g) == "b")
        #expect(e.ws.activeTab == nil)
    }

    @Test func leavingAGroupTabSaves() async throws {
        let e = Env(); defer { e.cleanup() }
        e.write("a", "one\n"); e.write("b", "two\n")
        let g = group(e)
        await e.ws.open("a", in: g)
        await e.ws.open("b", in: g)
        e.ws.activate("a", in: g)
        let doc = try #require(e.ws.document("a"))
        _ = doc.buffer.replace(0..<0, with: "x")
        e.ws.activate("b", in: g)
        await e.ws.settle()
        #expect(e.read("a") == "xone\n")
    }

    @Test func presentationIsPerPane() async throws {
        let e = Env(); defer { e.cleanup() }
        e.write("a", "one\n")
        let g = group(e)
        await e.ws.open("a", in: .chat)
        await e.ws.open("a", in: g)
        #expect(e.ws.presentation(of: "a", in: .chat) == .inline)
        #expect(e.ws.presentation(of: "a", in: g) == .plain)
        e.ws.setPresentation(.sideBySide, of: "a", in: .chat)
        #expect(e.ws.presentation(of: "a", in: g) == .plain)
        #expect(e.ws.presentation(of: "a", in: .chat) == .sideBySide)
        e.ws.setPresentation(.plain, of: "a", in: .chat)
        await e.ws.open("a", mode: .sideBySide, in: g)
        #expect(e.ws.presentation(of: "a", in: g) == .sideBySide)
        #expect(e.ws.presentation(of: "a", in: .chat) == .plain)
        await e.ws.close("a", in: g)
        #expect(e.ws.presentation(of: "a", in: g) == .plain)
    }

    @Test func outsideChangeReachesAGroupOnlyDocument() async throws {
        let e = Env(); defer { e.cleanup() }
        e.write("a.swift", "one\n")
        await e.ws.open("a.swift", in: group(e))
        let doc = try #require(e.ws.document("a.swift"))
        e.write("a.swift", "two\n")
        await e.fire(["a.swift"])
        #expect(String(decoding: doc.buffer.snapshot().utf8(in: 0..<doc.buffer.snapshot().utf8Count), as: UTF8.self) == "two\n")
    }

    @Test func saveAllCoversGroupOnlyDocuments() async throws {
        let e = Env(); defer { e.cleanup() }
        e.write("a.swift", "one\n")
        await e.ws.open("a.swift", in: group(e))
        let doc = try #require(e.ws.document("a.swift"))
        _ = doc.buffer.replace(0..<0, with: "x")
        await e.ws.saveAll()
        #expect(e.read("a.swift") == "xone\n")
    }

    @Test func readFinishingAfterLastHolderClosedInstallsNothing() async throws {
        let e = Env(); defer { e.cleanup() }
        e.write("a.swift", "one\n")
        let g = group(e)
        let opening = Task { await e.ws.open("a.swift", in: g) }
        await waitUntil("open started") { e.ws.tabs(in: g) == ["a.swift"] }
        await e.ws.close("a.swift", in: g)
        await opening.value
        #expect(e.ws.document("a.swift") == nil)
    }
}

@MainActor @Suite struct DocumentLifetimeFollowUpTests {
    private final class Flag: @unchecked Sendable { var fired = false }

    private func notified(_ read: @MainActor () -> Void, _ change: @MainActor () -> Void) -> Bool {
        let flag = Flag()
        withObservationTracking { read() } onChange: { flag.fired = true }
        change()
        return flag.fired
    }

    @Test func unchangedPresentationWritesDoNotNotify() async throws {
        let e = Env(); defer { e.cleanup() }
        e.write("a", "one\n")
        let g = PaneID.group(e.ws.codeLayout.focusedGroupID)
        await e.ws.open("a", in: g)
        e.ws.setPresentation(.sideBySide, of: "a", in: .chat)
        let same = notified({ _ = e.ws.presentation(of: "a", in: .chat) }, { e.ws.setPresentation(.sideBySide, of: "a", in: .chat) })
        #expect(!same)
        // The group has no entry, so closing its tab removes nothing.
        let noEntry = notified({ _ = e.ws.presentation(of: "a", in: .chat) }, { e.ws.removeTab("a", from: g) })
        #expect(!noEntry)
        let real = notified({ _ = e.ws.presentation(of: "a", in: .chat) }, { e.ws.setPresentation(.inline, of: "a", in: .chat) })
        #expect(real)
    }

    @Test func closingInChatLeavesTheGroupPresentationAndAutosave() async throws {
        let e = Env(); defer { e.cleanup() }
        e.write("a", "one\n")
        let g = PaneID.group(e.ws.codeLayout.focusedGroupID)
        await e.ws.open("a", in: .chat)
        await e.ws.open("a", mode: .sideBySide, in: g)
        await e.ws.close("a", in: .chat)
        #expect(e.ws.presentation(of: "a", in: g) == .sideBySide)
        let doc = try #require(e.ws.document("a"))
        _ = doc.buffer.replace(0..<0, with: "big ")
        await waitUntil("timer armed") { e.clock.pendingSleepers == 1 }
        e.clock.advance(by: 1.1)
        await waitUntil("autosave") { !doc.isDirty }
        #expect(e.read("a") == "big one\n")
    }

    @Test func groupOnlyBinaryTabRetriesWhenItBecomesText() async throws {
        let e = Env(); defer { e.cleanup() }
        e.write("a.txt", "one\n")
        let g = PaneID.group(e.ws.codeLayout.focusedGroupID)
        try Data([0x61, 0x00, 0x62]).write(to: e.url("a.txt"))
        await e.ws.open("a.txt", in: g)
        #expect(e.ws.tabMessages["a.txt"] == "Binary file")
        #expect(e.ws.tabs.isEmpty)
        e.write("a.txt", "text again\n")
        await e.fire(["a.txt"])
        #expect(e.ws.document("a.txt") != nil)
    }

    @Test func focusIgnoresUnknownGroups() {
        let layout = CodeLayout()
        let first = layout.focusedGroupID
        layout.focus(UUID())
        #expect(layout.focusedGroupID == first)
        #expect(layout.focusedGroup.id == first)
    }
}
