import AlloyCore
@testable import AlloyKit
import AlloyTestSupport
import Foundation
import MetalUI
import MetalUITesting
import Testing

@MainActor
@Suite(.serialized) struct MarkdownChatTests {

    private func wait(_ condition: @MainActor () -> Bool) async throws {
        for _ in 0..<20_000 {
            if condition() { return }
            await Task.yield()
        }
        Issue.record("timed out")
        throw CancellationError()
    }

    /// A rig whose session holds the given assistant texts, and a window over it.
    private func shown(_ texts: [String]) async throws -> (Rig, Session, TestWindow) {
        let rig = Rig()
        let session = await rig.workspace.newSession(name: "A")
        for (i, text) in texts.enumerated() {
            await rig.transports[0].emit(.assistantBlock(messageID: "m\(i)", block: .text(text)))
        }
        try await wait { session.transcript.blocks.count == texts.count }
        return (rig, session, try alloyWindow(rig.workspace))
    }

    /// The Copy buttons' identifiers, top to bottom.
    private func copyIDs(_ window: TestWindow) throws -> [String] {
        try window.elements(where: { $0.identifier?.hasPrefix("copy-code-") == true })
            .sorted { $0.frame.origin.y < $1.frame.origin.y }.compactMap(\.identifier)
    }

    /// The first Copy button (the one nearest the top).
    private func firstCopy(_ window: TestWindow) throws -> TestElement {
        try window.element(identifier: #require(copyIDs(window).first))
    }

    @Test func streamingAppendsOnly() {
        let cache = MarkdownCache()
        let first = cache.document(for: "b1", text: "Hello")
        #expect(first.version == 1)
        let second = cache.document(for: "b1", text: "Hello **world**")
        #expect(second.version == 2)
        #expect(cache.parseCount == 1)
        #expect(cache.appendCount == 1)
        // The same text again answers the cached document; no parse, no append.
        #expect(cache.document(for: "b1", text: "Hello **world**").version == 2)
        #expect(cache.parseCount == 1)
        // A text that does not extend the cached one parses anew; another block id has its own document.
        #expect(cache.document(for: "b1", text: "Different").version == 1)
        #expect(cache.document(for: "b2", text: "Other").version == 1)
        #expect(cache.parseCount == 3)
    }

    @Test func headingAndListRender() async throws {
        let (_, _, window) = try await shown(["# Release notes\n\n- first item\n- second item\n\n1. step one"])
        try await window.runUntil { (try? window.element(label: "Release notes")) != nil }
        let texts = try window.elements(where: { _ in true }).compactMap { $0.value ?? $0.label }
        for expected in ["Release notes", "first item", "second item", "step one"] {
            #expect(texts.contains { $0.contains(expected) }, "\(expected) in \(texts)")
        }
    }

    /// MetalUI's built-in Copy button (`showsCodeCopyButton`), found by its `copy-code-...` identifier (G15).
    @Test func codeFenceHasCopy() async throws {
        let code = "let answer = 42\nprint(answer)"
        let (_, _, window) = try await shown(["Here:\n\n```swift\n\(code)\n```\n\nDone."])
        try await window.runUntil { (try? firstCopy(window)) != nil }
        try window.click(firstCopy(window))
        window.tick()
        #expect(window.clipboardItems.count == 1)
        #expect(window.window.clipboard.read(String.self) == code)
    }

    /// Pressing Copy shows "Copied" for 1.5 s on the window's clock, then the label returns. The clock is driven, not slept.
    @Test func copyButtonShowsCopiedThenReverts() async throws {
        let (_, _, window) = try await shown(["- item\n\n  ```\n  one\n  ```\n\n  ```\n  two\n  ```\n"])
        try await window.runUntil { (try? copyIDs(window).count) == 2 }
        #expect(try firstCopy(window).label == "Copy code")
        try window.click(window.element(identifier: copyIDs(window)[1]))
        window.advanceFrames(2)
        #expect(try window.element(identifier: copyIDs(window)[1]).label == "Copied")
        #expect(try firstCopy(window).label == "Copy code")   // only the pressed block
        #expect(window.window.clipboard.read(String.self)?.contains("two") == true)
        window.advance(by: 1.3)
        #expect(try window.element(identifier: copyIDs(window)[1]).label == "Copied")   // still inside the 1.5 s
        window.advance(by: 0.3)
        window.advanceFrames(2)
        #expect(try window.element(identifier: copyIDs(window)[1]).label == "Copy code")
    }

    /// Two top-level fences in one reply get distinct ids (MetalUI numbers from 0 inside each block view, so the prefix
    /// carries the block's identity), and each button copies its own fence.
    @Test func topLevelFencesHaveDistinctCopyIdentifiers() async throws {
        let (_, _, window) = try await shown(["```\none\n```\n\n```\ntwo\n```", "```\nthree\n```"])
        try await window.runUntil { (try? copyIDs(window).count) == 3 }
        let ids = try copyIDs(window)
        #expect(Set(ids).count == 3, "\(ids)")
        try window.click(window.element(identifier: ids[1]))
        window.advanceFrames(2)
        #expect(window.window.clipboard.read(String.self) == "two")
        #expect(try window.element(identifier: ids[1]).label == "Copied")
        #expect(try window.element(identifier: ids[0]).label == "Copy code")
    }

    /// While a reply streams, the ids of the fences already there do not change when more text arrives.
    @Test func copyIdentifiersAreStableWhileStreaming() async throws {
        let rig = Rig()
        let session = await rig.workspace.newSession(name: "A")
        let t = rig.transports[0]
        await t.emit(.delta(.blockStart(index: 0, kind: "text")))
        await t.emit(.delta(.text(index: 0, "```\none\n```\n\nbetween\n\n```\ntw")))
        try await wait { session.transcript.blocks.count == 1 }
        let window = try alloyWindow(rig.workspace)
        try await window.runUntil { (try? copyIDs(window).count) == 2 }
        let before = try copyIDs(window)
        await t.emit(.delta(.text(index: 0, "o\n```\n\nafter\n\n```\nthree\n```")))
        try await window.runUntil { (try? copyIDs(window).count) == 3 }
        let after = try copyIDs(window)
        #expect(Array(after.prefix(2)) == before, "\(before) -> \(after)")
        #expect(Set(after).count == 3)
    }

    /// The old Copy button covered top-level fences only; the built-in one also covers a fence nested in a list.
    @Test func nestedFenceHasCopy() async throws {
        let (_, _, window) = try await shown(["- item\n\n  ```\n  nested_code()\n  ```\n"])
        try await window.runUntil { (try? firstCopy(window)) != nil }
        try window.click(firstCopy(window))
        window.tick()
        #expect(window.window.clipboard.read(String.self)?.contains("nested_code()") == true)
    }

    @Test func wheelOverCodeScrollsTranscript() async throws {
        let filler = (0..<30).map { "Paragraph \($0) of filler text that keeps the transcript taller than its window." }
        let wide = String(repeating: "wide_code_line_", count: 40)
        let (_, _, window) = try await shown(filler + ["```\n\(wide)\n```"])
        try await window.runUntil { (try? firstCopy(window)) != nil }
        window.tick()
        func codeText() throws -> TestElement {
            try #require(try window.elements(where: { ($0.value ?? $0.label)?.hasPrefix("wide_code_line_") == true }).first)
        }
        let button = try firstCopy(window).frame
        let code = try codeText().visibleFrame
        // The wheel point is well inside the visible code text, left of the Copy button.
        let point = Point(x: code.origin.x + Pixels(60), y: code.origin.y + code.size.height / 2)
        #expect(code.size.width > Pixels(100) && point.x < button.origin.x, "code \(code) button \(button)")
        #expect(point.x > code.origin.x && point.x < code.origin.x + code.size.width)
        #expect(point.y > code.origin.y && point.y < code.origin.y + code.size.height)

        // Control: a horizontal wheel at this point scrolls the code sideways and leaves the transcript alone. This
        // proves the point is over the horizontal scroller.
        let codeFrame0 = try codeText().frame, buttonY0 = button.origin.y
        window.scroll(at: point, byDeltaX: -40, deltaY: 0)
        let codeFrame1 = try codeText().frame
        #expect(codeFrame1.origin.x < codeFrame0.origin.x, "code did not scroll sideways: \(codeFrame0) -> \(codeFrame1)")
        #expect(try firstCopy(window).frame.origin.y == buttonY0)

        // A vertical wheel there reaches the transcript: it moves by the delta (20) and the code stays put sideways.
        // The transcript is pinned to the bottom, so a positive delta (content down) is the direction it can move.
        let beforeY = try firstCopy(window).frame.origin.y
        let beforeX = try codeText().frame.origin.x
        window.scroll(at: point, byDeltaX: 0, deltaY: 20)
        let afterY = try firstCopy(window).frame.origin.y
        #expect(abs((afterY - beforeY).value - 20) <= 2, "moved \((afterY - beforeY).value)")
        #expect(try codeText().frame.origin.x == beforeX)
    }
}
