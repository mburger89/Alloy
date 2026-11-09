import AlloyCore
@testable import AlloyKit
import AlloyTestSupport
import Foundation
import MetalUI
import MetalUITesting
import Testing

@MainActor
@Suite struct ComposerTests {
    private func settle(_ condition: @MainActor () -> Bool) async throws {
        for _ in 0..<20_000 {
            if condition() { return }
            await Task.yield()
        }
        Issue.record("timed out")
        throw CancellationError()
    }

    private func pollSent(_ rig: Rig, _ window: TestWindow? = nil, _ predicate: ([OutboundMessage]) -> Bool) async throws {
        for _ in 0..<200_000 {
            if predicate(await rig.transports[0].sent) { return }
            window?.tick()
            await Task.yield()
        }
        Issue.record("timed out waiting for outbound message")
        throw CancellationError()
    }

    private func idleSession(_ rig: Rig) async throws -> Session {
        let session = await rig.workspace.newSession(name: "A")
        await rig.transports[0].emit(.result(TurnResult(subtype: "success", isError: false, costUSD: 0, inputTokens: 0,
                                                        outputTokens: 0, sessionID: "s", terminalReason: nil)))
        try await settle { session.status == .idle }
        return session
    }

    private func workingSession(_ rig: Rig) async throws -> Session {
        let session = await rig.workspace.newSession(name: "A")
        await rig.transports[0].emit(.assistantBlock(messageID: "m1", block: .text("working")))
        try await settle { session.status == .working }
        return session
    }

    private func priorities(_ sent: [OutboundMessage]) -> [Priority?] {
        sent.compactMap { if case .user(_, _, let p) = $0 { .some(p) } else { nil } }
    }

    @Test func returnSendsWhenIdle() async throws {
        let rig = Rig()
        let session = try await idleSession(rig)
        let model = ComposerModel(workspace: rig.workspace, sessionID: session.id)
        model.draft = "  hello  "
        #expect(model.handleKey(.return, modifiers: []) == .handled)
        #expect(model.draft.isEmpty)
        try await pollSent(rig) { !priorities($0).isEmpty }
        #expect(priorities(await rig.transports[0].sent) == [nil])
        let texts: [[UserContent]] = await rig.transports[0].sent.compactMap { if case .user(let c, _, _) = $0 { c } else { nil } }
        #expect(texts == [[.text("hello")]])
    }

    @Test func emptyDraftDoesNothing() async throws {
        let rig = Rig()
        let session = try await idleSession(rig)
        let model = ComposerModel(workspace: rig.workspace, sessionID: session.id)
        model.draft = "  \n "
        #expect(model.handleKey(.return, modifiers: []) == .handled)
        for _ in 0..<50 { await Task.yield() }
        #expect(await rig.transports[0].sentAfterInitialize.isEmpty)
    }

    @Test func returnSteersWhenBusy() async throws {
        let rig = Rig()
        let session = try await workingSession(rig)
        let model = ComposerModel(workspace: rig.workspace, sessionID: session.id)
        model.draft = "change course"
        #expect(model.handleKey(.return, modifiers: []) == .handled)
        try await pollSent(rig) { !priorities($0).isEmpty }
        #expect(priorities(await rig.transports[0].sent) == [.next])
    }

    @Test func optionReturnQueues() async throws {
        let rig = Rig()
        let session = try await workingSession(rig)
        let model = ComposerModel(workspace: rig.workspace, sessionID: session.id)
        let window = try alloyWindow(rig.workspace)
        #expect((try? window.element(identifier: "queued-count")) == nil)
        model.draft = "later please"
        #expect(model.handleKey(.return, modifiers: .option) == .handled)
        try await pollSent(rig, window) { !priorities($0).isEmpty }
        #expect(priorities(await rig.transports[0].sent) == [.later])
        #expect(session.queued.count == 1)
        try await window.runUntil { (try? window.element(identifier: "queued-count")) != nil }
        _ = try window.element(label: "1 queued")
        // The CLI echoes the message with its uuid when it starts the turn.
        let uuid = try #require(session.queued.first)
        await rig.transports[0].emit(.userEcho(text: "later please", imageCount: 0, uuid: uuid.uuidString.lowercased(), isReplay: false))
        try await settle { session.queued.isEmpty }
        try await window.runUntil { (try? window.element(identifier: "queued-count")) == nil }
    }

    @Test func shiftReturnNewline() async throws {
        let rig = Rig()
        let session = try await idleSession(rig)
        let model = ComposerModel(workspace: rig.workspace, sessionID: session.id)
        model.draft = "line one"
        #expect(model.handleKey(.return, modifiers: .shift) == .ignored)
        #expect(model.draft == "line one")
        for _ in 0..<50 { await Task.yield() }
        #expect(await rig.transports[0].sentAfterInitialize.isEmpty)
    }

    @Test func shiftTabCyclesMode() async throws {
        let rig = Rig()
        let session = try await idleSession(rig)
        let model = ComposerModel(workspace: rig.workspace, sessionID: session.id)
        func modes(_ sent: [OutboundMessage]) -> [String] {
            sent.compactMap { if case .control(_, .setPermissionMode(let m)) = $0 { m } else { nil } }
        }
        for (i, expected) in ["acceptEdits", "plan", "default"].enumerated() {
            #expect(model.handleKey(.tab, modifiers: .shift) == .handled)
            try await pollSent(rig) { modes($0).count == i + 1 }
            #expect(modes(await rig.transports[0].sent).last == expected)
            // The CLI's status message carries the new mode.
            await rig.transports[0].emit(.statusChanged(permissionMode: expected))
            try await settle { session.permissionMode == expected }
        }
        #expect(model.handleKey(.tab, modifiers: []) == .ignored)
    }

    @Test func escapeInterruptsWhenWorkingElseClearsSuggestions() async throws {
        let rig = Rig()
        let session = try await workingSession(rig)
        let model = ComposerModel(workspace: rig.workspace, sessionID: session.id)
        #expect(model.handleKey(.escape, modifiers: []) == .handled)
        try await pollSent(rig) { if case .control(_, .interrupt)? = $0.last { true } else { false } }
        let idleRig = Rig()
        let idle = try await idleSession(idleRig)
        let idleModel = ComposerModel(workspace: idleRig.workspace, sessionID: idle.id)
        #expect(idleModel.handleKey(.escape, modifiers: []) == .ignored)
        let text = "@x"
        idleModel.suggestions = SuggestionState(kind: .file, query: "x", items: [.init(id: "x", title: "x", detail: nil)], selected: 0,
                                                tokenRange: text.startIndex..<text.endIndex)
        #expect(idleModel.handleKey(.escape, modifiers: []) == .handled)
        #expect(idleModel.suggestions == nil)
    }

    @Test func stopVisibleOnlyWhenWorking() async throws {
        let rig = Rig()
        let session = try await idleSession(rig)
        let window = try alloyWindow(rig.workspace)
        #expect((try? window.element(identifier: "stop")) == nil)
        await rig.transports[0].emit(.assistantBlock(messageID: "m1", block: .text("working")))
        try await settle { session.status == .working }
        try await window.runUntil { (try? window.element(identifier: "stop")) != nil }
        try window.click(window.element(identifier: "stop"))
        try await pollSent(rig, window) { if case .control(_, .interrupt)? = $0.last { true } else { false } }
    }

    @Test func stopVisibleWhileAwaitingPermission() async throws {
        let rig = Rig()
        let session = try await idleSession(rig)
        let window = try alloyWindow(rig.workspace)
        #expect((try? window.element(identifier: "stop")) == nil)
        await rig.transports[0].emit(.controlRequest(ControlRequest(requestID: "r1", kind: .canUseTool(
            toolName: "Bash", input: .object(["command": .string("ls")]), description: "ls", toolUseID: "tu1", suggestions: []))))
        try await settle { session.status == .awaitingPermission }
        try await window.runUntil { (try? window.element(identifier: "stop")) != nil }
        try window.click(window.element(identifier: "stop"))
        try await pollSent(rig, window) { if case .control(_, .interrupt)? = $0.last { true } else { false } }
    }

    @Test func modelMenuSetsModel() async throws {
        let rig = Rig()
        let session = try await idleSession(rig)
        let window = try alloyWindow(rig.workspace)
        try window.click(window.element(identifier: "model-menu"))
        window.tick()
        try window.chooseMenuItem("Opus")
        try await pollSent(rig, window) { $0.contains { if case .control(_, .setModel("opus")) = $0 { true } else { false } } }
        _ = session
    }

    /// G9: `/model` with no name opens the real model `Menu` (`model-menu`) through `.menuPresented`.
    @Test func slashModelOpensMenu() async throws {
        let rig = Rig()
        let session = try await idleSession(rig)
        let window = try alloyWindow(rig.workspace)
        #expect(window.presentedMenu == nil)
        try window.typeText("/model", into: window.element(identifier: "composer"))
        window.typeKey(.return)
        try await window.runUntil { window.presentedMenu != nil }
        #expect(window.presentedMenu != nil)
        #expect((try? window.element(identifier: "model-choice-haiku")) == nil)   // the inline stopgap row is gone
        try window.chooseMenuItem("Haiku")
        try await pollSent(rig, window) { $0.contains { if case .control(_, .setModel("haiku")) = $0 { true } else { false } } }
        #expect(!session.requestModelPicker)
        #expect(window.presentedMenu == nil)
    }

    /// Dismissing the opened menu with no choice clears the request and sends nothing.
    @Test func slashModelMenuDismissClearsRequest() async throws {
        let rig = Rig()
        let session = try await idleSession(rig)
        let window = try alloyWindow(rig.workspace)
        try window.typeText("/model", into: window.element(identifier: "composer"))
        window.typeKey(.return)
        try await window.runUntil { window.presentedMenu != nil }
        #expect(session.requestModelPicker)
        try window.dismissMenu()
        try await window.runUntil { !session.requestModelPicker }
        #expect(!session.requestModelPicker)
        #expect(window.presentedMenu == nil)
        let sent = await rig.transports[0].sent
        #expect(!sent.contains { if case .control(_, .setModel) = $0 { true } else { false } })
    }

    @Test func modePickerPresent() async throws {
        let rig = Rig()
        _ = try await idleSession(rig)
        let window = try alloyWindow(rig.workspace)
        #expect(try !window.elements(where: { $0.identifier == "mode-picker" }).isEmpty)
        _ = try window.element(identifier: "composer")
        _ = try window.element(identifier: "send")
    }
}
