import AlloyCore
@testable import AlloyKit
import AlloyTestSupport
import Foundation
import MetalUI
import MetalUITesting
import Testing

@MainActor
@Suite struct AutocompleteTests {
    private func settle(_ condition: @MainActor () -> Bool) async throws {
        for _ in 0..<50_000 {
            if condition() { return }
            await Task.yield()
        }
        Issue.record("timed out")
        throw CancellationError()
    }

    private let commands = [
        SlashCommandInfo(name: "commit", description: "Commit changes", argumentHint: nil),
        SlashCommandInfo(name: "compact", description: "Compact the conversation", argumentHint: "[focus]"),
        SlashCommandInfo(name: "cost", description: "Show cost", argumentHint: nil),
        SlashCommandInfo(name: "doctor", description: "Diagnose", argumentHint: nil),
    ]

    private func session(_ rig: Rig, working: Bool = false) async throws -> Session {
        let session = await rig.workspace.newSession(name: "A")
        let transport = rig.transports[0]
        await transport.emit(.systemInit(SystemInit(model: "m", permissionMode: "default", sessionID: "s", tools: [],
                                                    slashCommands: [], terminalSlashCommands: ["doctor"])))
        await transport.emit(.commandsChanged(commands))
        try await settle { session.slashCommands.count == 4 }
        if working {
            await transport.emit(.assistantBlock(messageID: "m1", block: .text("working")))
            try await settle { session.status == .working }
        } else {
            await transport.emit(.result(TurnResult(subtype: "success", isError: false, costUSD: 0, inputTokens: 0,
                                                    outputTokens: 0, sessionID: "s", terminalReason: nil)))
            try await settle { session.status == .idle }
        }
        return session
    }

    private func write(_ rig: Rig, _ path: String) throws {
        let url = rig.root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "x".write(to: url, atomically: true, encoding: .utf8)
    }

    @Test func slashOpensAndAccepts() async throws {
        let rig = Rig()
        let s = try await session(rig)
        let model = ComposerModel(workspace: rig.workspace, sessionID: s.id)
        model.draft = "/com"
        #expect(model.suggestions?.kind == .slash)
        #expect(model.suggestions?.items.map(\.title) == ["/commit", "/compact"])
        #expect(model.suggestions?.items[1].detail == "Compact the conversation [focus]")
        #expect(model.handleKey(.downArrow, modifiers: []) == .handled)
        #expect(model.suggestions?.selected == 1)
        #expect(model.handleKey(.return, modifiers: []) == .handled)
        #expect(model.draft == "/compact ")
        #expect(model.suggestions == nil)
        for _ in 0..<50 { await Task.yield() }
        #expect(await rig.transports[0].sentAfterInitialize.isEmpty)   // accepting did not send
    }

    @Test func returnOnAnExactSlashMatchSendsAtOnce() async throws {
        let rig = Rig()
        let s = try await session(rig)
        let model = ComposerModel(workspace: rig.workspace, sessionID: s.id)
        model.draft = "/compact"
        #expect(model.suggestions?.items.first?.id == "compact")
        #expect(model.handleKey(.return, modifiers: []) == .handled)   // the send itself
        #expect(model.draft.isEmpty)
        #expect(model.suggestions == nil)
        var sent: [OutboundMessage] = []
        for _ in 0..<200_000 where sent.isEmpty { await Task.yield(); sent = await rig.transports[0].sentAfterInitialize }
        guard case .user(let c, _, _)? = sent.first else { Issue.record("not sent: \(sent)"); return }
        #expect(c == [.text("/compact")])
    }

    @Test func tabOnAnExactSlashMatchOnlyAccepts() async throws {
        let rig = Rig()
        let s = try await session(rig)
        let model = ComposerModel(workspace: rig.workspace, sessionID: s.id)
        model.draft = "/compact"
        #expect(model.handleKey(.tab, modifiers: []) == .handled)
        #expect(model.draft == "/compact ")
        for _ in 0..<50 { await Task.yield() }
        #expect(await rig.transports[0].sentAfterInitialize.isEmpty)
    }

    @Test func upWrapsAndTypingRefilters() async throws {
        let rig = Rig()
        let s = try await session(rig)
        let model = ComposerModel(workspace: rig.workspace, sessionID: s.id)
        model.draft = "/co"
        #expect(model.suggestions?.items.count == 3)
        _ = model.handleKey(.upArrow, modifiers: [])
        #expect(model.suggestions?.selected == 2)
        model.draft = "/cos"
        #expect(model.suggestions?.items.map(\.title) == ["/cost"])
        #expect(model.suggestions?.selected == 0)
        model.draft = "/cost now"   // whitespace ends the token
        #expect(model.suggestions == nil)
    }

    @Test func slashOnlyAtDraftStart() async throws {
        let rig = Rig()
        let s = try await session(rig)
        let model = ComposerModel(workspace: rig.workspace, sessionID: s.id)
        model.draft = "see /com"
        #expect(model.suggestions == nil)
    }

    @Test func terminalOnlyHidden() async throws {
        let rig = Rig()
        let s = try await session(rig)
        let model = ComposerModel(workspace: rig.workspace, sessionID: s.id)
        model.draft = "/doc"
        #expect(model.suggestions?.items.isEmpty == true)
        model.draft = "/"
        #expect(model.suggestions?.items.map(\.title).contains("/doctor") == false)
    }

    @Test func atOpensFiles() async throws {
        let rig = Rig()
        let s = try await session(rig)
        try write(rig, "Sources/AlloyCore/Model/Workspace.swift")
        try write(rig, "README.md")
        let model = ComposerModel(workspace: rig.workspace, sessionID: s.id)
        model.draft = "look at @wor"
        #expect(model.suggestions?.kind == .file)
        try await settle { model.suggestions?.items.isEmpty == false }
        #expect(model.suggestions?.items.map(\.id) == ["Sources/AlloyCore/Model/Workspace.swift"])
        #expect(model.handleKey(.tab, modifiers: []) == .handled)
        #expect(model.draft == "look at @Sources/AlloyCore/Model/Workspace.swift ")
        #expect(model.suggestions == nil)
    }

    @Test func pathWithSpaceIsQuoted() async throws {
        let rig = Rig()
        let s = try await session(rig)
        try write(rig, "my docs/read me.md")
        let model = ComposerModel(workspace: rig.workspace, sessionID: s.id)
        model.draft = "@read"
        try await settle { model.suggestions?.items.isEmpty == false }
        _ = model.handleKey(.return, modifiers: [])
        #expect(model.draft == "@\"my docs/read me.md\" ")
        model.draft = "x @\"my docs/re"
        #expect(model.suggestions?.query == "my docs/re")
    }

    @Test func atNeedsWhitespaceBefore() async throws {
        let rig = Rig()
        let s = try await session(rig)
        let model = ComposerModel(workspace: rig.workspace, sessionID: s.id)
        model.draft = "mail me@host"
        #expect(model.suggestions == nil)
        model.draft = "@"
        #expect(model.suggestions?.kind == .file)
        model.draft = "done @a b"
        #expect(model.suggestions == nil)
    }

    @Test func escCloses() async throws {
        let rig = Rig()
        let s = try await session(rig)
        let model = ComposerModel(workspace: rig.workspace, sessionID: s.id)
        model.draft = "/co"
        #expect(model.handleKey(.escape, modifiers: []) == .handled)
        #expect(model.suggestions == nil)
        #expect(model.draft == "/co")
    }

    @Test func escWhileWorkingClosesWithoutInterrupt() async throws {
        let rig = Rig()
        let s = try await session(rig, working: true)
        let model = ComposerModel(workspace: rig.workspace, sessionID: s.id)
        model.draft = "/co"
        #expect(model.suggestions != nil)
        for key in [KeyEquivalent.downArrow, .upArrow] { #expect(model.handleKey(key, modifiers: []) == .handled) }
        #expect(model.handleKey(.escape, modifiers: []) == .handled)
        #expect(model.suggestions == nil)
        for _ in 0..<100 { await Task.yield() }
        let interrupts = await rig.transports[0].sent.filter { if case .control(_, .interrupt) = $0 { true } else { false } }
        #expect(interrupts.isEmpty)
        #expect(s.status == .working)
        // With the list closed, Esc interrupts as before.
        #expect(model.handleKey(.escape, modifiers: []) == .handled)
        for _ in 0..<100 { await Task.yield() }
        let after = await rig.transports[0].sent.filter { if case .control(_, .interrupt) = $0 { true } else { false } }
        #expect(after.count == 1)
    }

    @Test func escWithEmptyListInterruptsWorkingTurn() async throws {
        let rig = Rig()
        let s = try await session(rig, working: true)
        let model = ComposerModel(workspace: rig.workspace, sessionID: s.id)
        model.draft = "/zzz"
        #expect(model.suggestions?.items.isEmpty == true)
        #expect(model.handleKey(.upArrow, modifiers: []) == .ignored)
        #expect(model.handleKey(.escape, modifiers: []) == .handled)
        for _ in 0..<100 { await Task.yield() }
        let interrupts = await rig.transports[0].sent.filter { if case .control(_, .interrupt) = $0 { true } else { false } }
        #expect(interrupts.count == 1)
    }

    @Test func newAtTokenPicksUpNewFiles() async throws {
        let rig = Rig()
        let s = try await session(rig)
        try write(rig, "a.txt")
        let model = ComposerModel(workspace: rig.workspace, sessionID: s.id)
        model.draft = "@"
        try await settle { model.suggestions?.items.isEmpty == false }
        model.draft = ""
        try write(rig, "later.txt")
        model.draft = "@lat"
        // The rig keeps Alloy's own data (the shared knowledge pool) under support/, inside the project folder.
        try await settle { model.suggestions?.items.map(\.id).filter { !$0.hasPrefix("support/") } == ["later.txt"] }
    }

    @Test func returnWithNoMatchesSends() async throws {
        let rig = Rig()
        let s = try await session(rig)
        let model = ComposerModel(workspace: rig.workspace, sessionID: s.id)
        model.draft = "/zzz"
        #expect(model.suggestions?.items.isEmpty == true)
        #expect(!model.suggestionsVisible)
        #expect(model.handleKey(.return, modifiers: []) == .handled)
        #expect(model.draft.isEmpty)
    }

    @Test func overlayShowsRowsAndClickAccepts() async throws {
        let rig = Rig()
        _ = try await session(rig)
        let window = try alloyWindow(rig.workspace)
        let composer = try window.element(identifier: "composer")
        #expect((try? window.element(identifier: "suggestions")) == nil)
        try window.typeText("/com", into: composer)
        for _ in 0..<20 { window.tick(); await Task.yield() }
        try await window.runUntil { (try? window.element(identifier: "suggestions")) != nil }
        _ = try window.element(identifier: "suggestion-0")
        try window.click(window.element(identifier: "suggestion-1"))
        try await window.runUntil { (try? window.element(identifier: "suggestions")) == nil }
        window.tick()
        #expect(try window.element(identifier: "composer").value == "/compact ")
        #expect(try window.focusedElement?.identifier == "composer")   // the row press did not blur the field
    }

    // MARK: Caret (G11: `selectedOffsets` works on macOS 14; offsets are Characters)

    @Test func atTokenIsTheOneAtTheCaret() async throws {
        let rig = Rig()
        let s = try await session(rig)
        try write(rig, "Sources/AlloyCore/Model/Workspace.swift")
        let model = ComposerModel(workspace: rig.workspace, sessionID: s.id)
        model.draft = "look @wor and then more"
        model.caret = 9..<9   // right after "@wor"
        #expect(model.suggestions?.kind == .file)
        #expect(model.suggestions?.query == "wor")
        try await settle { model.suggestions?.items.isEmpty == false }
        #expect(model.handleKey(.tab, modifiers: []) == .handled)
        #expect(model.draft == "look @Sources/AlloyCore/Model/Workspace.swift and then more")
        let end = "look @Sources/AlloyCore/Model/Workspace.swift ".count
        #expect(model.caret == end..<end)
    }

    @Test func slashCompletesAtTheCaretNotTheEnd() async throws {
        let rig = Rig()
        let s = try await session(rig)
        let model = ComposerModel(workspace: rig.workspace, sessionID: s.id)
        model.draft = "/cost later"
        model.caret = 3..<3   // "/co|st later": whitespace is after the caret, so the token is "/co"
        #expect(model.suggestions?.kind == .slash)
        #expect(model.suggestions?.query == "co")
        model.caret = 7..<7   // moved past the space: no token
        #expect(model.suggestions == nil)
    }

    @Test func caretMovesAfterAcceptanceAndMentionsInsertAtCaret() async throws {
        let rig = Rig()
        let s = try await session(rig)
        let model = ComposerModel(workspace: rig.workspace, sessionID: s.id)
        model.draft = "/com"
        model.caret = 4..<4
        model.acceptSuggestion(at: 1)
        #expect(model.draft == "/compact ")
        #expect(model.caret == 9..<9)
        model.draft = "abcd"
        model.caret = 2..<2
        model.insertMention("@x")
        #expect(model.draft == "ab @x cd")
        #expect(model.caret == 6..<6)
        model.draft = "ab cd"
        model.caret = 3..<3   // before a word, after a space: no leading space
        model.insertMention("@y")
        #expect(model.draft == "ab @y cd")
        #expect(model.caret == 6..<6)
        model.draft = "ab"
        model.caret = nil     // unknown caret: the end, as before
        model.insertMention("@z")
        #expect(model.draft == "ab @z ")
        #expect(model.caret == 6..<6)
        model.draft = "é👍é"   // Character offsets, not UTF-8 bytes
        model.caret = 2..<2
        model.insertMention("@w")
        #expect(model.draft == "é👍 @w é")
    }

    /// End to end through the real editor: typing after an accepted suggestion lands after it, and a drop lands at the
    /// caret the user left, not at the end.
    @Test func typingAfterAcceptanceAndDropAtCaret() async throws {
        let rig = Rig()
        _ = try await session(rig)
        try write(rig, "src/main.swift")
        let window = try alloyWindow(rig.workspace)
        let composer = try window.element(identifier: "composer")
        try window.typeText("/com", into: composer)
        try await window.runUntil { (try? window.element(identifier: "suggestions")) != nil }
        try window.click(window.element(identifier: "suggestion-1"))
        try await window.runUntil { (try? window.element(identifier: "suggestions")) == nil }
        window.typeText("x")
        window.tick()
        #expect(try window.element(identifier: "composer").value == "/compact x")
        // Move the caret left past "x" and the space, then type: it lands mid-text.
        window.typeKey(.leftArrow)
        window.typeKey(.leftArrow)
        window.typeText("Y")
        window.tick()
        #expect(try window.element(identifier: "composer").value == "/compactY x")
    }

    @Test func fileDropInsertsAtTheCaret() async throws {
        let rig = Rig()
        _ = try await session(rig)
        try write(rig, "src/main.swift")
        let window = try alloyWindow(rig.workspace)
        let composer = try window.element(identifier: "composer")
        try window.typeText("one two", into: composer)
        window.typeKey(.leftArrow); window.typeKey(.leftArrow); window.typeKey(.leftArrow); window.typeKey(.leftArrow)   // "one| two"
        window.tick()
        let url = rig.root.appendingPathComponent("src/main.swift")
        let frame = try window.element(identifier: "composer").frame
        let type = PasteboardType(identifier: "public.file-url", conformsTo: ["public.url", "public.data", "public.item"])
        let bytes = [UInt8](url.absoluteString.utf8)
        window.drop([DropItem(types: [type]) { $0 == type.identifier ? bytes : nil }],
                    at: Point(x: frame.origin.x + Pixels(10), y: frame.origin.y + Pixels(10)))
        window.tick()
        #expect(try window.element(identifier: "composer").value == "one @src/main.swift two")
    }

    @Test func filteringHundredThousandPathsIsFast() {
        let paths = (0..<100_000).map { "Sources/Module\($0 % 300)/Group\($0 % 17)/File\($0).swift" }
        let start = ContinuousClock.now
        let top = FuzzyMatch.top("mgf12", in: paths)
        let elapsed = ContinuousClock.now - start
        #expect(!top.isEmpty)
        #expect(elapsed < .seconds(5))   // debug build; the composer runs this off the main actor
    }
}
