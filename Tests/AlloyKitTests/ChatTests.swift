import AlloyCore
@testable import AlloyKit
import AlloyTestSupport
import Foundation
import MetalUI
import MetalUITesting
import Testing

@MainActor
@Suite struct ChatTests {
    private let oldText = "let role = \"admin\"\n"
    private let newText = "let role = \"root\"\n"

    /// A session with one Edit tool call applied to `login.swift` (the file on disk holds the new text).
    private func editedRig() async throws -> (rig: Rig, session: Session, editID: UUID) {
        let rig = Rig()
        let session = await rig.workspace.newSession(name: "A")
        let url = rig.root.appendingPathComponent("login.swift")
        try newText.write(to: url, atomically: true, encoding: .utf8)
        await rig.transports[0].emit(.assistantBlock(messageID: "m1", block: .toolUse(
            id: "tool1", name: "Edit", input: .object(["file_path": .string(url.path)]))))
        await rig.transports[0].emit(.toolResult(ToolResultMessage(
            toolUseID: "tool1", isError: false, text: "ok",
            result: .edit(filePath: url.path, originalFile: oldText, hunks: [
                PatchHunk(oldStart: 1, oldLines: 1, newStart: 1, newLines: 1,
                          lines: ["-let role = \"admin\"", "+let role = \"root\""])]))))
        try await until { toolEditIDs(session).count == 1 }
        return (rig, session, toolEditIDs(session)[0])
    }

    private func toolEditIDs(_ session: Session) -> [UUID] {
        for case .tool(let t) in session.transcript.blocks where t.toolUseID == "tool1" { return t.editIDs }
        return []
    }

    @Test func userAndAssistantTextAppear() async throws {
        let rig = Rig()
        let session = await rig.workspace.newSession(name: "A")
        let window = try alloyWindow(rig.workspace)
        try window.typeText("hello", into: window.element(identifier: "composer"))
        window.typeKey(.return, modifierFlags: .primary)
        try await pollSent(rig, window) { $0.contains { if case .user(let c, _, _) = $0 { c == [.text("hello")] } else { false } } }
        try await window.runUntil { (try? window.element(label: "hello")) != nil }
        await rig.transports[0].emit(.assistantBlock(messageID: "m1", block: .text("Hi there")))
        try await window.runUntil { (try? window.element(label: "Hi there")) != nil }
        #expect(session.transcript.blocks.count == 2)
    }

    @Test func imageOnlyAndQueuedBubblesSayWhatTheyAre() async throws {
        let rig = Rig()
        let session = await rig.workspace.newSession(name: "A")
        await rig.transports[0].emit(.assistantBlock(messageID: "m1", block: .text("working")))
        try await until { session.status == .working }
        let image = ImageAttachment(mediaType: "image/png", base64: "AAAA", pixelSize: (2, 2), byteCount: 3)
        await rig.workspace.send(OutgoingMessage(text: "", images: [image], priority: .later), to: session.id)
        await rig.workspace.send(OutgoingMessage(text: "steer", images: [image, image], priority: .next), to: session.id)
        let window = try alloyWindow(rig.workspace)
        func labels(_ prefix: String) throws -> [String] {
            try window.elements(where: { $0.identifier?.hasPrefix(prefix) == true }).compactMap { $0.value ?? $0.label }
        }
        try await window.runUntil { ((try? labels("user-state-").count) ?? 0) == 2 }
        #expect(try labels("user-images-").sorted() == ["1 image", "2 images"])
        #expect(try labels("user-state-").sorted() == ["Queued", "Steering"])
    }

    @Test func userBubbleHelpers() {
        #expect(UserBubble.imageCaption(0) == nil)
        #expect(UserBubble.imageCaption(1) == "1 image")
        #expect(UserBubble.imageCaption(3) == "3 images")
        #expect(UserBubble.stateLabel(.sent) == nil)
        #expect(UserBubble.stateLabel(.queued(.later)) == "Queued")
        #expect(UserBubble.stateLabel(.queued(.next)) == "Steering")
    }

    @Test func blankComposerDoesNotSend() async throws {
        let rig = Rig()
        _ = await rig.workspace.newSession(name: "A")
        let window = try alloyWindow(rig.workspace)
        try window.typeText("   ", into: window.element(identifier: "composer"))
        window.typeKey(.return, modifierFlags: .primary)
        try window.click(window.element(identifier: "send"))
        for _ in 0..<50 { window.tick(); await Task.yield() }
        #expect(await rig.transports[0].sentAfterInitialize.isEmpty)
    }

    @Test func noSessionShowsHint() async throws {
        let rig = Rig()
        let window = try alloyWindow(rig.workspace)
        #expect((try? window.element(label: "Start a session with ⌘N")) != nil)
    }

    @Test func toolBlockShowsKindAndSummary() async throws {
        let (rig, _, _) = try await editedRig()
        let window = try alloyWindow(rig.workspace)
        try await window.runUntil { (try? window.element(identifier: "block-tool1")) != nil }
        let block = try window.element(identifier: "block-tool1")
        let texts = descendants(of: block, in: window).compactMap { $0.value ?? $0.label }
        #expect(texts.contains("Edit login.swift"), "\(texts)")
        #expect(texts.contains("let role = \"admin\""), "\(texts)")
        #expect(texts.contains("let role = \"root\""), "\(texts)")
    }

    @Test func approveButtonSendsAllow() async throws {
        let rig = Rig()
        _ = await rig.workspace.newSession(name: "A")
        await rig.transports[0].emit(.controlRequest(ControlRequest(requestID: "r1", kind: .canUseTool(
            toolName: "Bash", input: .object(["command": .string("ls")]), description: nil, toolUseID: "t9", suggestions: []))))
        let window = try alloyWindow(rig.workspace)
        try await window.runUntil { (try? window.element(identifier: "approve-r1")) != nil }
        try window.click(window.element(identifier: "approve-r1"))
        try await pollSent(rig, window) { if case .allow(let id, _, _)? = $0.last { id == "r1" } else { false } }
        try await window.runUntil { (try? window.element(label: "Allowed")) != nil }
    }

    @Test func denyButtonSendsDeny() async throws {
        let rig = Rig()
        _ = await rig.workspace.newSession(name: "A")
        await rig.transports[0].emit(.controlRequest(ControlRequest(requestID: "r2", kind: .canUseTool(
            toolName: "Bash", input: .object(["command": .string("ls")]), description: nil, toolUseID: "t9", suggestions: []))))
        let window = try alloyWindow(rig.workspace)
        try await window.runUntil { (try? window.element(identifier: "deny-r2")) != nil }
        try window.click(window.element(identifier: "deny-r2"))
        try await pollSent(rig, window) { $0.last == .deny(requestID: "r2", message: "Denied in Alloy") }
        try await window.runUntil { (try? window.element(label: "Denied")) != nil }
    }

    @Test func escapeInterrupts() async throws {
        let rig = Rig()
        let session = await rig.workspace.newSession(name: "A")
        await rig.transports[0].emit(.assistantBlock(messageID: "m1", block: .text("working")))
        try await until { session.status == .working }
        let window = try alloyWindow(rig.workspace)
        try window.click(window.element(identifier: "composer"))
        window.typeKey(.escape)
        try await pollSent(rig, window) { if case .control(_, .interrupt)? = $0.last { true } else { false } }
    }

    @Test func escapeWhenIdleDoesNothing() async throws {
        let rig = Rig()
        let session = await rig.workspace.newSession(name: "A")
        await rig.transports[0].emit(.result(TurnResult(subtype: "success", isError: false, costUSD: 0, inputTokens: 0,
                                                        outputTokens: 0, sessionID: "s", terminalReason: nil)))
        try await until { session.status == .idle }
        let window = try alloyWindow(rig.workspace)
        try window.click(window.element(identifier: "composer"))
        window.typeKey(.escape)
        for _ in 0..<50 { window.tick(); await Task.yield() }
        #expect(await rig.transports[0].sentAfterInitialize.isEmpty)
    }

    @Test func revertButtonRevertsEdit() async throws {
        let (rig, _, editID) = try await editedRig()
        let window = try alloyWindow(rig.workspace)
        try await window.runUntil { (try? window.element(identifier: "revert-\(editID.uuidString)")) != nil }
        try window.click(window.element(identifier: "revert-\(editID.uuidString)"))
        let url = rig.root.appendingPathComponent("login.swift")
        try await window.runUntil { (try? String(contentsOf: url, encoding: .utf8)) == oldText }
        try await window.runUntil { (try? window.element(label: "Reverted")) != nil }
    }

    @Test func keepButtonMarksKept() async throws {
        let (rig, _, editID) = try await editedRig()
        let window = try alloyWindow(rig.workspace)
        try await window.runUntil { (try? window.element(identifier: "keep-\(editID.uuidString)")) != nil }
        try window.click(window.element(identifier: "keep-\(editID.uuidString)"))
        try await window.runUntil { (try? window.element(label: "Kept")) != nil }
    }

    @Test func diffComputedOncePerLedgerVersion() async throws {
        let (rig, session, editID) = try await editedRig()
        let window = try alloyWindow(rig.workspace)
        try await window.runUntil { (try? window.element(identifier: "keep-\(editID.uuidString)")) != nil }
        let before = rig.workspace.diffComputations
        #expect(before == 1)
        for i in 0..<5 {
            await rig.transports[0].emit(.assistantBlock(messageID: "s\(i)", block: .text("streamed \(i)")))
            try await window.runUntil { (try? window.element(label: "streamed \(i)")) != nil }
        }
        #expect(rig.workspace.diffComputations == before)
        #expect(session.transcript.blocks.count >= 6)
        _ = rig.workspace.diffLines(path: "login.swift")
        #expect(rig.workspace.diffComputations == before)
        rig.workspace.keep(edit: editID, path: "login.swift")
        _ = rig.workspace.diffLines(path: "login.swift")
        #expect(rig.workspace.diffComputations == before + 1)
    }

    @Test func revertConflictSurvivesRecreatingTheView() async throws {
        let (rig, a, editID) = try await editedRig()
        // Someone changes the edited line outside Alloy: the revert must refuse.
        try "let role = \"someone-else\"\n".write(to: rig.root.appendingPathComponent("login.swift"), atomically: true, encoding: .utf8)
        let window = try alloyWindow(rig.workspace)
        try await window.runUntil { (try? window.element(identifier: "revert-\(editID.uuidString)")) != nil }
        try window.click(window.element(identifier: "revert-\(editID.uuidString)"))
        try await window.runUntil { rig.workspace.revertConflicts[editID] != nil }
        func shown() -> Bool {
            let reason = rig.workspace.revertConflicts[editID] ?? "?"
            return (try? window.element(label: reason)) != nil
        }
        try await window.runUntil { shown() }
        let b = await rig.workspace.newSession(name: "B")
        rig.workspace.selectedSessionID = b.id
        try await window.runUntil { (try? window.element(identifier: "revert-\(editID.uuidString)")) == nil }
        rig.workspace.selectedSessionID = a.id
        try await window.runUntil { shown() }
    }

    @Test func openingALongSessionShowsTheLastBlock() async throws {
        let rig = Rig()
        let session = await rig.workspace.newSession(name: "A")
        for i in 0..<60 {
            await rig.transports[0].emit(.assistantBlock(messageID: "m\(i)", block: .text("block number \(i)\nsecond line")))
        }
        try await until { session.transcript.blocks.count == 60 }
        let window = try alloyWindow(rig.workspace)
        let lastID = try #require(session.transcript.blocks.last?.id)
        try await window.runUntil {
            guard let e = try? window.element(identifier: "block-\(lastID)") else { return false }
            return e.frame.maxY.value <= 800 && e.frame.minY.value >= 0
        }
    }

    @Test func shellOutputIsCappedAtSixLinesUntilTheEyeOpensIt() async throws {
        let rig = Rig()
        _ = await rig.workspace.newSession(name: "A")
        await rig.transports[0].emit(.assistantBlock(messageID: "m1", block: .toolUse(
            id: "sh1", name: "Bash", input: .object(["command": .string("seq 30")]))))
        let out = (0..<30).map { "out-line-\($0)" }.joined(separator: "\n")
        await rig.transports[0].emit(.toolResult(ToolResultMessage(toolUseID: "sh1", isError: false, text: out, result: .none)))
        let window = try alloyWindow(rig.workspace)
        func text() -> String {
            guard let block = try? window.element(identifier: "block-sh1") else { return "" }
            return descendants(of: block, in: window).compactMap { $0.value ?? $0.label }.joined(separator: "\n")
        }
        try await window.runUntil { text().contains("out-line-5") }
        #expect(!text().contains("out-line-6"))
        try window.click(window.element(identifier: "code-toggle-sh1-output"))
        try await window.runUntil { text().contains("out-line-29") }
        #expect(try window.element(identifier: "code-toggle-sh1-output").label == "Show less")
    }

    @Test func cancelledPermissionShowsCancelled() async throws {
        let rig = Rig()
        _ = await rig.workspace.newSession(name: "A")
        await rig.transports[0].emit(.controlRequest(ControlRequest(requestID: "r3", kind: .canUseTool(
            toolName: "Bash", input: .object([:]), description: "ls", toolUseID: nil, suggestions: []))))
        await rig.transports[0].emit(.controlCancel(requestID: "r3"))
        let window = try alloyWindow(rig.workspace)
        try await window.runUntil { (try? window.element(label: "Cancelled")) != nil }
        #expect((try? window.element(identifier: "approve-r3")) == nil)
    }

    @Test func thinkingAndNoticesRender() async throws {
        let rig = Rig()
        let a = await rig.workspace.newSession(name: "A")
        await rig.transports[0].emit(.assistantBlock(messageID: "m1", block: .thinking("pondering the login")))
        let window = try alloyWindow(rig.workspace)
        try await window.runUntil { (try? window.element(label: "pondering the login")) != nil }
        let texts = try window.elements(where: { ($0.value ?? $0.label)?.hasPrefix("Thinking") == true })
        #expect(!texts.isEmpty)
        await rig.transports[0].exit(status: 1, stderr: "boom")
        try await until { if case .exited = a.status { true } else { false } }
        try await window.runUntil { (try? window.element(label: "Claude exited (status 1): boom")) != nil }
    }

    @Test func replayingTheEditTurnFixtureShowsItsDiff() async throws {
        let rig = Rig()
        let session = await rig.workspace.newSession(name: "A")
        let url = try #require(Bundle.module.url(forResource: "edit-turn", withExtension: "jsonl", subdirectory: "Fixtures"))
        let probeRoot = "/tmp/alloy-fixture"
        let raw = try String(contentsOf: url, encoding: .utf8).replacingOccurrences(of: probeRoot, with: rig.root.path)
        let lines = raw.split(separator: "\n").map { Data($0.utf8) }
        await rig.transports[0].emit(fixture: lines)
        try await until { session.transcript.blocks.contains { if case .tool(let t) = $0 { !t.editIDs.isEmpty } else { false } } }
        let toolID = try #require(session.transcript.blocks.compactMap { b -> String? in
            if case .tool(let t) = b, t.kind == .edit { t.toolUseID } else { nil } }.first)
        let window = try alloyWindow(rig.workspace)
        try await window.runUntil { (try? window.element(identifier: "block-\(toolID)")) != nil }
        let block = try window.element(identifier: "block-\(toolID)")
        let texts = descendants(of: block, in: window).compactMap { $0.value ?? $0.label }
        #expect(texts.contains { $0.contains("user == \"admin\"") }, "\(texts)")
        #expect(texts.contains { $0.contains("user == \"root\"") }, "\(texts)")
        #expect(texts.contains { $0.hasPrefix("Edit login.swift") }, "\(texts)")
    }
}

@MainActor
private func until(_ condition: @MainActor () -> Bool) async throws {
    for _ in 0..<20_000 {
        if condition() { return }
        await Task.yield()
    }
    Issue.record("timed out")
    throw CancellationError()
}

/// Ticks the window until the transport's sent log satisfies `predicate`.
@MainActor
private func pollSent(_ rig: Rig, _ window: TestWindow, _ predicate: ([OutboundMessage]) -> Bool) async throws {
    for _ in 0..<200_000 {
        if predicate(await rig.transports[0].sent) { return }
        window.tick()
        await Task.yield()
    }
    Issue.record("timed out waiting for outbound message")
    throw CancellationError()
}
