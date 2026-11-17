import AlloyCore
import AlloyLSP
@testable import AlloyKit
import AlloyTestSupport
import Foundation
import MetalUI
import MetalUICodeBuffer
import MetalUITesting
import Testing

private let source = "let x = f\n"
private let endOfLine = 9

private let one = IntelRig.signatureAnswer([("f(a: Int, b: Int)", ["a: Int", "b: Int"])])
private let second = IntelRig.signatureAnswer([("f(a: Int, b: Int)", ["a: Int", "b: Int"])], active: 1)

@MainActor
@Suite
struct SignatureHelpPanelTests {
    private func start(_ r: IntelRig) async throws -> (TestWindow, EditorDocument, CodeSelectionState) {
        try r.write("main.rs", source)
        let window = try await r.open("main.rs")
        let doc = try #require(r.rig.workspace.document("main.rs"))
        let state = try #require(r.rig.workspace.selectionState(for: "main.rs", in: .chat))
        state.select(endOfLine..<endOfLine, reveal: false)
        return (window, doc, state)
    }

    private func model(_ r: IntelRig) throws -> IntelligenceOverlayModel {
        let doc = try #require(r.rig.workspace.document("main.rs"))
        return try #require(CodePanelStore.existingView(for: doc)).overlayModel
    }

    @Test func aTriggerCharacterShowsTheStrip() async throws {
        try await IntelRig.run(script: IntelRig.signatureScript(answers: one)) { r in
            let (window, _, _) = try await start(r)
            window.typeText("(")
            try await window.runUntil { r.exists(window, "signature-help") }
            let strip = try #require(model(r).signature)
            #expect(strip.label == "f(a: Int, b: Int)")
            #expect(strip.parts.1 == "a: Int")
            #expect(!r.exists(window, "completion-popup"))
        }
    }

    @Test func aRetriggerCharacterMovesTheActiveParameter() async throws {
        try await IntelRig.run(script: IntelRig.signatureScript(answers: "\(one),\(second)")) { r in
            let (window, _, _) = try await start(r)
            window.typeText("(")
            try await window.runUntil { r.exists(window, "signature-help") }
            window.typeText("1,")
            try await window.runUntil { (try? model(r).signature?.parts.1) == "b: Int" }
            #expect(r.count("textDocument/signatureHelp") >= 2)
        }
    }

    @Test func theStripSitsAboveAnOpenCompletionList() async throws {
        let script = IntelRig.signatureScript(answers: one, completion: #"{"result":[{"label":"foo"}]}"#)
        try await IntelRig.run(script: script) { r in
            let (window, _, _) = try await start(r)
            window.typeText("(")
            try await window.runUntil { r.exists(window, "signature-help") }
            window.typeText("f")
            try await window.runUntil { r.exists(window, "completion-popup") }
            #expect(r.exists(window, "signature-help"))
            let strip = try #require(window.element(identifier: "signature-help").frame)
            let list = try #require(window.element(identifier: "completion-popup").frame)
            #expect(strip.origin.y.value < list.origin.y.value)
        }
    }

    @Test func optionArrowsCycleOverloadsAndWrap() async throws {
        let two = IntelRig.signatureAnswer([("f(a: Int)", ["a: Int"]), ("f(a: Int, b: Int)", ["a: Int", "b: Int"])])
        try await IntelRig.run(script: IntelRig.signatureScript(answers: two)) { r in
            let (window, _, _) = try await start(r)
            window.typeText("(")
            try await window.runUntil { r.exists(window, "signature-help") }
            #expect(try model(r).signature?.index == 0)
            window.typeKey(.downArrow, modifierFlags: .option)
            #expect(try model(r).signature?.label == "f(a: Int, b: Int)")
            window.typeKey(.downArrow, modifierFlags: .option)
            #expect(try model(r).signature?.index == 0)
            window.typeKey(.upArrow, modifierFlags: .option)
            #expect(try model(r).signature?.index == 1)
        }
    }

    @Test func aNullAnswerClosesIt() async throws {
        try await IntelRig.run(script: IntelRig.signatureScript(answers: "\(one),{\"result\":null}")) { r in
            let (window, _, _) = try await start(r)
            window.typeText("(")
            try await window.runUntil { r.exists(window, "signature-help") }
            window.typeText(")")
            try await window.runUntil { !r.exists(window, "signature-help") }
        }
    }

    @Test func escapeClosesTheListFirstThenTheStrip() async throws {
        let script = IntelRig.signatureScript(answers: one, completion: #"{"result":[{"label":"foo"}]}"#)
        try await IntelRig.run(script: script) { r in
            let (window, _, _) = try await start(r)
            window.typeText("(")
            try await window.runUntil { r.exists(window, "signature-help") }
            window.typeText("f")
            try await window.runUntil { r.exists(window, "completion-popup") }
            window.typeKey(.escape)
            try await window.runUntil { !r.exists(window, "completion-popup") }
            #expect(r.exists(window, "signature-help"))
            window.typeKey(.escape)
            try await window.runUntil { !r.exists(window, "signature-help") }
        }
    }

    @Test func movingLeftOfTheCallClosesIt() async throws {
        try await IntelRig.run(script: IntelRig.signatureScript(answers: one)) { r in
            let (window, _, _) = try await start(r)
            window.typeText("(")
            try await window.runUntil { r.exists(window, "signature-help") }
            window.typeKey(.leftArrow)
            try await window.runUntil { !r.exists(window, "signature-help") }
        }
    }

    @Test func controlShiftSpaceOpensItWithNoTyping() async throws {
        try await IntelRig.run(script: IntelRig.signatureScript(answers: one)) { r in
            let (window, _, _) = try await start(r)
            window.typeKey(.space, modifierFlags: [.control, .shift])
            try await window.runUntil { r.exists(window, "signature-help") }
            #expect(r.count("textDocument/signatureHelp") == 1)
        }
    }

    @Test func anInvokedStripSurvivesTypingAndUpdates() async throws {
        try await IntelRig.run(script: IntelRig.signatureScript(answers: "\(one),\(one),\(second)")) { r in
            let (window, _, _) = try await start(r)
            window.typeKey(.space, modifierFlags: [.control, .shift])
            try await window.runUntil { r.exists(window, "signature-help") }
            window.typeText("a")
            try await window.runUntil { r.count("textDocument/signatureHelp") >= 2 }
            #expect(r.exists(window, "signature-help"))
            window.typeText(",")
            try await window.runUntil { (try? model(r).signature?.parts.1) == "b: Int" }
            #expect(r.exists(window, "signature-help"))
        }
    }

    @Test func theMenuItemOpensIt() async throws {
        try await IntelRig.run(script: IntelRig.signatureScript(answers: one)) { r in
            let (window, _, _) = try await start(r)
            try window.testApp.performMenuBarItem(accessibilityIdentifier: "menu-signature-help")
            try await window.runUntil { r.exists(window, "signature-help") }
        }
    }

    @Test func aStaleAnswerAfterMoreTypingIsDropped() async throws {
        let slow = IntelRig.signatureAnswer([("STALE(a)", ["a"])], delayMs: 400)
        try await IntelRig.run(script: IntelRig.signatureScript(answers: slow)) { r in
            let (window, _, _) = try await start(r)
            window.typeText("(")
            try await window.runUntil { r.count("textDocument/signatureHelp") == 1 }
            window.typeText("a")
            await r.idle(window, 0.8)
            #expect(try model(r).signature == nil)
            #expect(!r.exists(window, "signature-help"))
        }
    }

    @Test func twoCaretsOrASelectionNeverOpenIt() async throws {
        try await IntelRig.run(script: IntelRig.signatureScript(answers: one)) { r in
            let (window, _, state) = try await start(r)
            state.select(0..<3, reveal: false)
            window.typeKey(.space, modifierFlags: [.control, .shift])
            state.setSelections([CodeSelection(caret: 0), CodeSelection(caret: endOfLine)], primary: 1)
            window.typeKey(.space, modifierFlags: [.control, .shift])
            window.typeText("(")
            await r.idle(window, 0.4)
            #expect(!r.exists(window, "signature-help"))
            #expect(r.count("textDocument/signatureHelp") == 0)
        }
    }

    @Test func theActiveParameterLandsOnTheRightCharactersWithAnEmoji() async throws {
        let answer = #"{"result":{"signatures":[{"label":"f(😀: Int, b: Int)","parameters":[{"label":[2,9]},{"label":[11,17]}]}],"activeParameter":1}}"#
        try await IntelRig.run(script: IntelRig.signatureScript(answers: answer)) { r in
            let (window, _, _) = try await start(r)
            window.typeText("(")
            try await window.runUntil { r.exists(window, "signature-help") }
            #expect(try model(r).signature?.parts.1 == "b: Int")
            #expect(try model(r).signature?.parts.0 == "f(😀: Int, ")
        }
    }

    @Test func noSchedulerStateWithoutTheCapability() async throws {
        try await IntelRig.run(script: IntelRig.completionScript(completion: #"{"result":[]}"#)) { r in
            let (window, _, _) = try await start(r)
            window.typeText("(")
            await r.idle(window, 0.3)
            #expect(r.count("textDocument/signatureHelp") == 0)
        }
    }
}
