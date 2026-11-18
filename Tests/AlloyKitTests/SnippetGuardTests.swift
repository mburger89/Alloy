import AlloyCore
import AlloyLSP
@testable import AlloyKit
import AlloyTestSupport
import Foundation
import MetalUI
import MetalUICodeBuffer
import MetalUITesting
import Testing

/// The frame guards with a running snippet session: typing inside a placeholder costs what plain typing costs (never
/// raise a constant), an idle session and a chat view cost nothing extra, and ending the session restores plain typing.
@MainActor
@Suite struct SnippetGuardTests {
    private typealias Perf = CodeModePerformanceTests

    /// First answer: the snippet; later answers: nothing, so typing inside a placeholder opens no popup.
    private static let script = IntelRig.completionScript(
        completion: #"{"result":[{"label":"call","insertText":"call(${1:a}, ${2:b})$0","insertTextFormat":2}]},{"result":[]}"#)

    /// Clicks the view, types a prefix, accepts the snippet item; the session starts on the first placeholder.
    private func startSession(_ intel: IntelRig, _ window: TestWindow, _ id: String) async throws -> (CodeSelectionState, EditorDocument) {
        for _ in 0..<10 { window.tick(); await Task.yield() }
        try window.click(window.element(identifier: id))
        for _ in 0..<5 { window.tick(); await Task.yield() }
        let doc = try #require(intel.rig.workspace.document("login.swift"))
        let state = try #require(intel.rig.workspace.selectionState(for: "login.swift", in: intel.rig.workspace.defaultPane))
        window.typeText("c")
        try await window.runUntil { intel.exists(window, "completion-popup") }
        window.typeKey(.return)
        for _ in 0..<5 { window.tick(); await Task.yield() }
        #expect(state.isSnippetActive, "session started")
        return (state, doc)
    }

    /// The counted typing frames of `Perf.typing`, without its click (which would move the caret off the session).
    private func countedTyping(_ window: TestWindow, doc: EditorDocument, names: [String]) async -> Perf.Typing {
        let version = doc.buffer.version
        window.resetFrameWork()
        for i in 0..<40 {
            window.typeText("a"); window.tick(); await Task.yield()
            let last = window.frameWork.suffix(2).map(\.elementRequests)
            if i >= 9, last.count == 2, last[0] == last[1] { break }
        }
        window.resetFrameWork()
        var reruns: [String: Int] = [:]
        let allBefore = BodyProbe.counts
        for _ in 0..<20 {
            let before = names.map(BodyProbe.count)
            window.typeText("a"); window.tick()
            for (i, n) in names.enumerated() { reruns[n, default: 0] += BodyProbe.count(n) - before[i] }
            await Task.yield()
        }
        let work = window.frameWork.map(\.elementRequests)
        let bodies = BodyProbe.counts.reduce(0) { $0 + $1.value - (allBefore[$1.key] ?? 0) }
        return Perf.Typing(perFrame: work, requests: work.reduce(0, +), bodies: bodies, reruns: reruns, documentGrew: doc.buffer.version != version)
    }

    private func expectGuard(_ t: Perf.Typing, steady: Int, chat: Int, _ label: String) {
        print("SNIPPETGUARD \(label) perFrame=\(t.perFrame) requests=\(t.requests) bodies=\(t.bodies)")
        #expect(t.documentGrew)
        #expect(t.perFrame.allSatisfy { $0 <= steady }, "\(label) per-frame element requests \(t.perFrame)")
        #expect(t.requests <= steady * 20, "\(label) element requests \(t.requests)")
        #expect(t.reruns["CodePanel"] == 0, "\(label) CodePanel re-ran \(t.reruns["CodePanel"] ?? -1) times")
        for n in ["CodeIslandRow", "EditorAreaView", "CodeChatColumn", "CodeSidebarView", "TitleIsland", "IslandBackdrop",
                  "GlassBackdrop", "ChatView", "ChatColumn", "TranscriptView", "AlloyScreen"] {
            #expect(t.reruns[n] == 0, "\(label) \(n) re-ran \(t.reruns[n] ?? -1) times")
        }
        #expect(t.bodies <= chat, "\(label) bodies \(t.bodies) > chat \(chat)")
    }

    @Test func snippetSessionTypingCode1() async throws {
        let perf = Perf()
        let (intel, window, id) = try await IntelRig.guardRig(layout: .code1, script: Self.script)
        let (state, doc) = try await startSession(intel, window, id)
        let t = await countedTyping(window, doc: doc, names: Perf.watched)
        #expect(state.isSnippetActive, "the session survived the typing")
        expectGuard(t, steady: Perf.steadyCode1, chat: try await perf.chatBodies(), "session code1")
        withExtendedLifetime((intel, window)) {}
    }

    /// Chat has no code view, so no session; the snippet-capable script leaves chat typing at the chat guard.
    @Test func snippetSessionTypingChat() async throws {
        let perf = Perf()
        let (intel, window, id) = try await IntelRig.guardRig(layout: .chat, script: Self.script)
        let t = try await perf.typing(window, intel.rig, codeViewID: id, names: Perf.watched)
        print("SNIPPETGUARD chat perFrame=\(t.perFrame) requests=\(t.requests)")
        #expect(t.documentGrew)
        #expect(t.perFrame.allSatisfy { $0 <= ViewRerunTests.steadyFrameRequests }, "chat per-frame \(t.perFrame)")
        #expect(t.reruns["CodePanel"] == 0)
        withExtendedLifetime((intel, window)) {}
    }

    @Test func snippetSessionIdleCode1() async throws {
        let perf = Perf()
        let (intel, window, id) = try await IntelRig.guardRig(layout: .code1, script: Self.script)
        let (state, _) = try await startSession(intel, window, id)
        for _ in 0..<15 { window.tick(); await Task.yield() }
        window.resetFrameWork()
        var reruns: [String: Int] = [:]
        for _ in 0..<20 {
            for (k, v) in perf.allProbes({ window.tick() }) { reruns[k, default: 0] += v }
            await Task.yield()
        }
        let requests = window.frameWork.reduce(0) { $0 + $1.elementRequests }
        print("SNIPPETGUARD idle requests=\(requests) reruns=\(reruns)")
        #expect(state.isSnippetActive)
        #expect(reruns.isEmpty, "idle ticks re-ran \(reruns)")
        #expect(requests == 0, "idle session cost \(requests) element requests")
        withExtendedLifetime((intel, window)) {}
    }

    @Test func closedPopupWithoutASessionStillMatchesCode1() async throws {
        let perf = Perf()
        let (intel, window, id) = try await IntelRig.guardRig(layout: .code1, script: Self.script)
        let (state, doc) = try await startSession(intel, window, id)
        window.typeKey(.escape)
        for _ in 0..<5 { window.tick(); await Task.yield() }
        #expect(!state.isSnippetActive, "Esc ended the session")
        let t = await countedTyping(window, doc: doc, names: Perf.watched)
        expectGuard(t, steady: Perf.steadyCode1, chat: try await perf.chatBodies(), "post-session code1")
        withExtendedLifetime((intel, window)) {}
    }
}
