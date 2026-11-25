import AlloyCore
@testable import AlloyKit
import AlloyTestSupport
import Foundation
import MetalUI
import MetalUITesting
import Testing

@MainActor
@Suite struct ComposerSizeTests {
    private func rigWithSession() async throws -> (Rig, Session, TestWindow) {
        let rig = Rig()
        let session = await rig.workspace.newSession(name: "A")
        let window = try alloyWindow(rig.workspace)
        return (rig, session, window)
    }

    /// Types `lines` into the composer, a ⇧Return between them.
    private func type(lines: Int, window: TestWindow) throws {
        try window.focus(window.element(identifier: "composer"))
        for i in 0..<lines {
            window.typeText("line \(i)")
            if i < lines - 1 { window.typeKey(.return, modifierFlags: .shift) }
        }
        window.tick(); window.tick()
    }

    /// The box is the field plus the 6 pt inset above and below; the plain field is 16 pt at one line and grows 16 pt per line to 128 (G18).
    private func height(_ id: String, _ window: TestWindow) throws -> Float {
        try window.element(identifier: id).frame.size.height.value
    }

    @Test func emptyDraftIsOneLineHigh() async throws {
        let (_, _, window) = try await rigWithSession()
        #expect(try height("composer", window) == 16)
        #expect(try height("composer-box", window) == 16 + 12)
    }

    @Test func threeLinesAreThreeLinesHigh() async throws {
        let (_, _, window) = try await rigWithSession()
        try type(lines: 3, window: window)
        #expect(try height("composer", window) == 48)
    }

    @Test func fortyLinesAreCappedAtEightAndKeepAcceptingText() async throws {
        let (_, _, window) = try await rigWithSession()
        try type(lines: 40, window: window)
        #expect(try height("composer", window) == 128)
        #expect(try height("composer-box", window) == 128 + 12)
        // Capped, yet the editor still holds (and scrolls to) the whole text.
        let value = try window.element(identifier: "composer").value ?? ""
        #expect(value.hasSuffix("line 39"))
        #expect(try window.element(identifier: "composer").isFocused)
    }

    @Test func oneLongWrappedLineGrowsTheBox() async throws {
        let (_, _, window) = try await rigWithSession()
        try window.focus(window.element(identifier: "composer"))
        window.typeText(String(repeating: "word ", count: 120))
        window.tick(); window.tick()
        let grown = try height("composer", window)
        #expect(grown > 16)
        #expect(grown <= 128)
        #expect(!(try #require(window.element(identifier: "composer").value)).contains("\n"))
    }

    @Test func aVeryLongWrappedLineCapsAt128AndScrolls() async throws {
        let (_, _, window) = try await rigWithSession()
        try window.focus(window.element(identifier: "composer"))
        window.typeText(String(repeating: "word ", count: 2_000))
        window.tick(); window.tick()
        #expect(try height("composer", window) == 128)
        #expect(try window.element(identifier: "composer").isFocused)
    }

    @Test func textIsInsetFromTheBorderAndSendSitsOnTheBottomEdge() async throws {
        let (_, _, window) = try await rigWithSession()
        let box = try window.element(identifier: "composer-box").frame
        let editor = try window.element(identifier: "composer").frame
        #expect(editor.origin.x.value - box.origin.x.value >= 8)
        #expect(editor.origin.y.value - box.origin.y.value >= 6)
        let send = try window.element(identifier: "send").frame
        #expect(abs((send.origin.y.value + send.size.height.value) - (box.origin.y.value + box.size.height.value)) <= 1)
    }
}
