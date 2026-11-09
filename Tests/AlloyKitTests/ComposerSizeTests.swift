import AlloyCore
@testable import AlloyKit
import AlloyTestSupport
import Foundation
import MetalUI
import MetalUITesting
import Testing

@MainActor
@Suite struct ComposerSizeTests {
    private func rigWithSession() async -> (Rig, Session, TestWindow) {
        let rig = Rig()
        let session = await rig.workspace.newSession(name: "A")
        let window = try! alloyWindow(rig.workspace)
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

    /// The box is the editor plus the 6 pt inset above and below; the editor shows whole 16 pt lines.
    private func height(_ id: String, _ window: TestWindow) throws -> Float {
        try window.element(identifier: id).frame.size.height.value
    }

    @Test func emptyDraftIsOneLineHigh() async throws {
        let (_, _, window) = await rigWithSession()
        #expect(try height("composer", window) == 16)
        #expect(try height("composer-box", window) == 16 + 12)
    }

    @Test func threeLinesAreThreeLinesHigh() async throws {
        let (_, _, window) = await rigWithSession()
        try type(lines: 3, window: window)
        #expect(try height("composer", window) == 48)
    }

    @Test func fortyLinesAreCappedAtEightAndKeepAcceptingText() async throws {
        let (_, _, window) = await rigWithSession()
        try type(lines: 40, window: window)
        #expect(try height("composer", window) == 8 * 16)
        #expect(try height("composer-box", window) == 8 * 16 + 12)
        // Capped, yet the editor still holds (and scrolls to) the whole text.
        let value = try window.element(identifier: "composer").value ?? ""
        #expect(value.hasSuffix("line 39"))
        #expect(try window.element(identifier: "composer").isFocused)
    }

    @Test func oneLongLineStaysOneRow() async throws {
        let (_, _, window) = await rigWithSession()
        try window.focus(window.element(identifier: "composer"))
        window.typeText(String(repeating: "word ", count: 120))
        window.tick(); window.tick()
        #expect(try height("composer", window) == 16)
    }

    @Test func textIsInsetFromTheBorderAndSendSitsOnTheBottomEdge() async throws {
        let (_, _, window) = await rigWithSession()
        let box = try window.element(identifier: "composer-box").frame
        let editor = try window.element(identifier: "composer").frame
        #expect(editor.origin.x.value - box.origin.x.value >= 8)
        #expect(editor.origin.y.value - box.origin.y.value >= 6)
        let send = try window.element(identifier: "send").frame
        #expect(abs((send.origin.y.value + send.size.height.value) - (box.origin.y.value + box.size.height.value)) <= 1)
    }
}
