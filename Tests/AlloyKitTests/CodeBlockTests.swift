import AlloyCore
import AlloyHighlight
@testable import AlloyKit
import AlloyTestSupport
import Foundation
import MetalUI
import MetalUITesting
import Testing

/// Chat code blocks: the shared view behind the shell, read, write and edit bodies.
@MainActor
@Suite struct CodeBlockTests {
    private let keeper = RigKeeper()

    private func shellResult(_ out: String, err: String = "") -> JSONValue {
        .object(["stdout": .string(out), "stderr": .string(err), "interrupted": .bool(false)])
    }

    /// One finished tool call, rendered. `open` clicks the header of a block that starts collapsed.
    private func render(name: String, id: String, input: JSONValue, text: String, raw: JSONValue?,
                        open: Bool = false, isError: Bool = false) async throws -> (TestWindow, Session) {
        let rig = Rig()
        keeper.append(rig)
        let session = await rig.workspace.newSession(name: "A")
        let t = rig.transports[0]
        await t.emit(.assistantBlock(messageID: "m1", block: .toolUse(id: id, name: name, input: input)))
        await t.emit(.toolResult(ToolResultMessage(toolUseID: id, isError: isError, text: text, result: .none, raw: raw)))
        try await settle { session.transcript.blocks.contains { if case .tool(let b) = $0 { b.endedAt != nil } else { false } } }
        let window = try alloyWindow(rig.workspace)
        try await window.runUntil { (try? window.element(identifier: "block-header-\(id)")) != nil }
        if open {
            try window.click(window.element(identifier: "block-header-\(id)"))
            window.tick()
        }
        return (window, session)
    }

    private func shell(id: String, command: String, out: String, err: String = "") async throws -> TestWindow {
        try await render(name: "Bash", id: id, input: .object(["command": .string(command)]), text: out,
                         raw: shellResult(out, err: err)).0
    }

    /// The distinct glyph colours drawn inside a code block, clear of its gutter and its buttons.
    private func colours(_ window: TestWindow, in id: String) throws -> Set<[Float]> {
        let box = try window.element(identifier: id).frame
        let minX = Float(box.minX.value) + 40, maxX = Float(box.maxX.value) - 70
        let minY = Float(box.minY.value), maxY = Float(box.maxY.value)
        var set = Set<[Float]>()
        for g in window.scene.glyphs {
            let b = g.bounds
            guard b.origin.x >= minX, b.origin.x + b.size.width <= maxX, b.origin.y >= minY, b.origin.y + b.size.height <= maxY else { continue }
            set.insert([g.color.h, g.color.s, g.color.l, g.color.a])
        }
        return set
    }

    private func waitForColours(_ window: TestWindow, in id: String, atLeast n: Int) async throws {
        try await window.runUntil { ((try? colours(window, in: id).count) ?? 0) >= n }
    }

    private var longCommand: String { (1...10).map { "echo row\($0) | sed 's/a/b/'" }.joined(separator: "\n") }

    // MARK: collapse and the eye

    @Test func longCommandCollapsesToSixLinesAndTheEyeToggles() async throws {
        let window = try await shell(id: "s1", command: longCommand, out: "ok")
        try await window.runUntil { (try? window.element(identifier: "code-toggle-s1-command")) != nil }
        #expect((try? window.element(label: "echo row6 | sed 's/a/b/'")) != nil)
        #expect((try? window.element(label: "echo row7 | sed 's/a/b/'")) == nil)
        let eye = try window.element(identifier: "code-toggle-s1-command")
        #expect(eye.label == "Show all 10 lines")
        try window.click(eye)
        try await window.runUntil { (try? window.element(label: "echo row10 | sed 's/a/b/'")) != nil }
        #expect(try window.element(identifier: "code-toggle-s1-command").label == "Show less")
        // Line numbers stay while expanded.
        #expect((try? window.element(label: "10")) != nil)
        try window.click(window.element(identifier: "code-toggle-s1-command"))
        try await window.runUntil { (try? window.element(label: "echo row7 | sed 's/a/b/'")) == nil }
        #expect(try window.element(identifier: "code-toggle-s1-command").label == "Show all 10 lines")
    }

    @Test func eachPartHasItsOwnToggle() async throws {
        let out = (1...9).map { "out\($0)" }.joined(separator: "\n")
        let window = try await shell(id: "s2", command: longCommand, out: out)
        try await window.runUntil { (try? window.element(identifier: "code-toggle-s2-output")) != nil }
        try window.click(window.element(identifier: "code-toggle-s2-output"))
        try await window.runUntil { (try? window.element(label: "out9")) != nil }
        #expect((try? window.element(label: "echo row7 | sed 's/a/b/'")) == nil)   // the command stayed collapsed
        #expect(try window.element(identifier: "code-toggle-s2-command").label == "Show all 10 lines")
    }

    @Test func shortBlocksHaveNoEye() async throws {
        let window = try await shell(id: "s3", command: "ls", out: "a\nb")
        try await window.runUntil { (try? window.element(identifier: "code-copy-s3-command")) != nil }
        #expect((try? window.element(identifier: "code-toggle-s3-command")) == nil)
        #expect((try? window.element(identifier: "code-toggle-s3-output")) == nil)
    }

    @Test func eyeSitsInTheTopRightOfItsOwnContainer() async throws {
        let window = try await shell(id: "s4", command: longCommand, out: "ok")
        try await window.runUntil { (try? window.element(identifier: "code-toggle-s4-command")) != nil }
        let box = try window.element(identifier: "code-s4-command").frame
        let eye = try window.element(identifier: "code-toggle-s4-command").frame
        #expect(eye.maxX.value <= box.maxX.value && box.maxX.value - eye.maxX.value < 16, "\(eye) in \(box)")
        #expect(eye.minY.value >= box.minY.value && eye.minY.value - box.minY.value < 16, "\(eye) in \(box)")
        #expect(eye.minX.value > (box.minX.value + box.maxX.value) / 2)
    }

    // MARK: languages

    @Test func commandIsBashColoured() async throws {
        let window = try await shell(id: "s5", command: "for f in *.txt; do\n  echo \"$f\" | wc -l\ndone", out: "")
        try await waitForColours(window, in: "code-s5-command", atLeast: 2)
        #expect(try colours(window, in: "code-s5-command").count > 1)
    }

    @Test func catOutputOfAKnownFileIsColouredAndLsStaysPlain() async throws {
        let py = "def greet(name):\n    return \"hello \" + name\n"
        let cat = try await shell(id: "s6", command: "cat src/x.py", out: py)
        try await waitForColours(cat, in: "code-s6-output", atLeast: 2)
        let ls = try await shell(id: "s7", command: "ls src", out: "x.py\ny.py\nz.py")
        try await ls.runUntil { (try? ls.element(identifier: "code-s7-output")) != nil }
        for _ in 0..<6 { ls.tick() }
        #expect(try colours(ls, in: "code-s7-output").count == 1)
    }

    // MARK: read, write, edit

    @Test func readLineNumbersStartAtStartLine() async throws {
        let raw: JSONValue = .object(["type": .string("text"), "file": .object([
            "filePath": .string("/x/greet.py"), "content": .string("def greet(name):\n    return name\n"),
            "numLines": .number(2), "startLine": .number(40), "totalLines": .number(60)])])
        let (window, _) = try await render(name: "Read", id: "r1", input: .object(["file_path": .string("/x/greet.py"), "offset": .number(40)]),
                                           text: "40\tdef greet(name):", raw: raw, open: true)
        try await window.runUntil { (try? window.element(label: "40")) != nil }
        #expect((try? window.element(label: "41")) != nil)
        #expect((try? window.element(label: "1")) == nil)
        try await waitForColours(window, in: "code-r1-content", atLeast: 2)
    }

    @Test func diffKeepsItsTintsAndGainsSyntaxColours() async throws {
        let rig = Rig()
        keeper.append(rig)
        let session = await rig.workspace.newSession(name: "A")
        let url = rig.root.appendingPathComponent("login.swift")
        try "let role = \"root\"\n".write(to: url, atomically: true, encoding: .utf8)
        await rig.transports[0].emit(.assistantBlock(messageID: "m1", block: .toolUse(
            id: "e1", name: "Edit", input: .object(["file_path": .string(url.path)]))))
        await rig.transports[0].emit(.toolResult(ToolResultMessage(
            toolUseID: "e1", isError: false, text: "ok",
            result: .edit(filePath: url.path, originalFile: "let role = \"admin\"\n", hunks: [
                PatchHunk(oldStart: 1, oldLines: 1, newStart: 1, newLines: 1,
                          lines: ["-let role = \"admin\"", "+let role = \"root\""])]))))
        try await settle { session.transcript.blocks.contains { if case .tool(let t) = $0 { t.editIDs.count == 1 } else { false } } }
        let window = try alloyWindow(rig.workspace)
        try await window.runUntil { (try? window.element(identifier: "code-e1-diff")) != nil }
        try await waitForColours(window, in: "code-e1-diff", atLeast: 2)
        let box = try window.element(identifier: "code-e1-diff").frame
        var fills = Set<[Float]>()
        for r in window.scene.rects where r.background.a > 0 {
            let x0 = r.bounds.origin.x, y0 = r.bounds.origin.y
            let x1 = x0 + r.bounds.size.width, y1 = y0 + r.bounds.size.height
            let inside = x0 >= box.minX.value && y0 >= box.minY.value && x1 <= box.maxX.value && y1 <= box.maxY.value
            if inside { fills.insert([r.background.h, r.background.s, r.background.l, r.background.a]) }
        }
        #expect(fills.count >= 2, "add and remove tints: \(fills)")
    }

    // MARK: copy

    @Test func copyCopiesTheFullTextNotTheVisibleLines() async throws {
        let window = try await shell(id: "s8", command: longCommand, out: "ok")
        try await window.runUntil { (try? window.element(identifier: "code-copy-s8-command")) != nil }
        try window.click(window.element(identifier: "code-copy-s8-command"))
        window.tick()
        #expect(window.window.clipboard.read(String.self) == longCommand)
    }

    // MARK: fix round 1

    private func numbered(_ n: Int, prefix: String = "r") -> String { (1...n).map { "\(prefix)\($0)" }.joined(separator: "\n") }

    @Test func expandedBlocksStopAtFiveHundredRows() async throws {
        let window = try await shell(id: "cap1", command: "seq 700", out: numbered(700))
        try await window.runUntil { (try? window.element(identifier: "code-toggle-cap1-output")) != nil }
        try window.click(window.element(identifier: "code-toggle-cap1-output"))
        try await window.runUntil { (try? window.element(label: "r500")) != nil }
        #expect((try? window.element(label: "r501")) == nil)
        #expect((try? window.element(label: "Copy to get all 700 lines")) != nil)
    }

    @Test func readNoteOpensTheFileAtTheFirstHiddenLine() async throws {
        let rig = Rig()
        keeper.append(rig)
        let url = rig.root.appendingPathComponent("big.py")
        try numbered(700, prefix: "v").write(to: url, atomically: true, encoding: .utf8)
        let session = await rig.workspace.newSession(name: "A")
        let raw: JSONValue = .object(["type": .string("text"), "file": .object([
            "filePath": .string(url.path), "content": .string(numbered(700, prefix: "v")),
            "numLines": .number(700), "startLine": .number(1), "totalLines": .number(700)])])
        await rig.transports[0].emit(.assistantBlock(messageID: "m1", block: .toolUse(id: "rd", name: "Read", input: .object(["file_path": .string(url.path)]))))
        await rig.transports[0].emit(.toolResult(ToolResultMessage(toolUseID: "rd", isError: false, text: "1\tv1", result: .none, raw: raw)))
        try await settle { session.transcript.blocks.contains { if case .tool(let b) = $0 { b.endedAt != nil } else { false } } }
        let window = try alloyWindow(rig.workspace)
        try await window.runUntil { (try? window.element(identifier: "block-header-rd")) != nil }
        try window.click(window.element(identifier: "block-header-rd"))
        try await window.runUntil { (try? window.element(identifier: "code-toggle-rd-content")) != nil }
        try window.click(window.element(identifier: "code-toggle-rd-content"))
        try await window.runUntil { (try? window.element(identifier: "code-open-rd-content")) != nil }
        try window.click(window.element(identifier: "code-open-rd-content"))
        try await window.runUntil { rig.workspace.activeTab == "big.py" }
    }

    @Test func failedShellBlocksUseCodeBlocksToo() async throws {
        let heredoc = "cat <<'EOF' > x.py\n" + numbered(9, prefix: "line") + "\nEOF"
        let err = "Error: Exit code 1\n" + numbered(8, prefix: "oops")
        let (window, _) = try await render(name: "Bash", id: "f1", input: .object(["command": .string(heredoc)]), text: err, raw: nil, isError: true)
        try await window.runUntil { (try? window.element(identifier: "code-toggle-f1-command")) != nil }
        #expect(try window.element(identifier: "code-toggle-f1-command").label == "Show all 11 lines")
        #expect((try? window.element(identifier: "code-copy-f1-command")) != nil)
        #expect((try? window.element(identifier: "code-toggle-f1-error")) != nil)
        #expect((try? window.element(label: "oops6")) == nil)
    }

    @Test func collapsedBlockHighlightsOnlyItsSixVisibleLines() async throws {
        let big = (1...1000).map { "x\($0) = \($0)" }.joined(separator: "\n")
        let window = try await shell(id: "h1", command: "cat big.py", out: big)
        try await waitForColours(window, in: "code-h1-output", atLeast: 2)
        for _ in 0..<5 { window.tick() }
        #expect(CodeHighlight.requests(tag: "h1-output") == [6])
        // Opening it highlights what is then shown, and keeps the first six lines' colours meanwhile.
        try window.click(window.element(identifier: "code-toggle-h1-output"))
        try await window.runUntil { CodeHighlight.requests(tag: "h1-output").count == 2 }
        #expect(CodeHighlight.requests(tag: "h1-output") == [6, 500])
    }

    @Test func copyShowsCopiedForOneAndAHalfSeconds() async throws {
        let window = try await shell(id: "cp1", command: longCommand, out: "ok")
        try await window.runUntil { (try? window.element(identifier: "code-copy-cp1-command")) != nil }
        #expect(try window.element(identifier: "code-copy-cp1-command").label == "Copy")
        try window.click(window.element(identifier: "code-copy-cp1-command"))
        window.advanceFrames(2)
        #expect(try window.element(identifier: "code-copy-cp1-command").label == "Copied")
        window.advance(by: 1.7)
        window.advanceFrames(2)
        #expect(try window.element(identifier: "code-copy-cp1-command").label == "Copy")
    }

    @Test func eyeStateSurvivesASessionSwitch() async throws {
        let rig = Rig()
        keeper.append(rig)
        let a = await rig.workspace.newSession(name: "A")
        _ = await rig.workspace.newSession(name: "B")
        rig.workspace.selectedSessionID = a.id
        let t = rig.transports[0]
        await t.emit(.assistantBlock(messageID: "m1", block: .toolUse(id: "sw", name: "Bash", input: .object(["command": .string(longCommand)]))))
        await t.emit(.toolResult(ToolResultMessage(toolUseID: "sw", isError: false, text: "ok", result: .none, raw: shellResult("ok"))))
        let window = try alloyWindow(rig.workspace)
        try await window.runUntil { (try? window.element(identifier: "code-toggle-sw-command")) != nil }
        try window.click(window.element(identifier: "code-toggle-sw-command"))
        try await window.runUntil { (try? window.element(identifier: "code-toggle-sw-command"))?.label == "Show less" }
        rig.workspace.selectedSessionID = rig.workspace.sessions.first { $0.id != a.id }?.id
        window.tick(); window.tick()
        #expect((try? window.element(identifier: "code-toggle-sw-command")) == nil)
        rig.workspace.selectedSessionID = a.id
        try await window.runUntil { (try? window.element(identifier: "code-toggle-sw-command")) != nil }
        #expect(try window.element(identifier: "code-toggle-sw-command").label == "Show less")
    }

    @Test func partNamesForSeveralEditsAndWrites() {
        let edit = ToolBlock(toolUseID: "e", name: "Edit", kind: .edit, summary: "")
        let write = ToolBlock(toolUseID: "w", name: "Write", kind: .write, summary: "")
        #expect(DiffSection.part(edit, index: 0) == "diff" && DiffSection.part(edit, index: 1) == "diff2")
        #expect(DiffSection.part(write, index: 0) == "content")
    }

    @Test func storeKeepsColoursAcrossRebuildsOfTheSameInput() {
        let store = CodeBlockStore()
        let first = store.item(id: "a-output", fingerprint: 1) { ([CodeLine(text: "x", number: 1)], []) }
        first.colours = [AttributedString("x")]
        #expect(store.item(id: "a-output", fingerprint: 1) { ([], []) } === first)
        #expect(store.item(id: "a-output", fingerprint: 2) { ([], []) } !== first)
    }

    @Test func supersededHighlightStopsAndReturnsNothing() async {
        let task = Task.detached { () -> [AttributedString]? in
            while !Task.isCancelled { await Task.yield() }
            return CodeHighlight.attributed(lines: ["x = 1"], plan: [OutputSection(lines: 0..<1, language: .python)], scheme: .light, tag: nil)
        }
        task.cancel()
        #expect(await task.value == nil)
    }

    @Test func equalsDumpsNeedTheLoopThatCatsTheEchoedFile() {
        let out = ["=== a.py", "x = 1", "=== b.py", "y = 2"]
        let sections = OutputColouring.sections([OutputSection(lines: 0..<2, language: .python), OutputSection(lines: 2..<4, language: .python)])
        #expect(ToolBodies.outputColouring(command: "for f in a.py b.py; do echo \"=== $f\"; cat \"$f\"; done", output: out) == sections)
        #expect(ToolBodies.outputColouring(command: "echo \"=== a.py\"; cat a.py; echo \"=== b.py\"; cat b.py", output: out) == sections)
        #expect(ToolBodies.outputColouring(command: "echo \"=== a.py\"; ls", output: out) == .plain)
        #expect(ToolBodies.outputColouring(command: "cat <<'EOF'\n=== a.py\nEOF", output: out) == .plain)
        #expect(ToolBodies.outputColouring(command: "for f in a.py; do echo \"=== $f\"; cat $f | head -3; done", output: out) == .plain)
    }

    @Test func gutterNumbersFollowTheDisplayedFile() {
        func view(_ c: String, _ o: [String]) -> ShellOutputView { ToolBodies.shellOutputView(command: c, output: o) }
        let o = ["a", "b", "c"]
        #expect(view("cat x.py", o).numbers == [1, 2, 3])
        #expect(view("head -n 3 x.py", o).numbers == [1, 2, 3])
        #expect(view("sed -n '40,42p' x.py", o).numbers == [40, 41, 42])
        #expect(view("tail -n 3 x.py", o).numbers == [nil, nil, nil])
        #expect(view("tail -3 x.py", o).numbers == [nil, nil, nil])
        #expect(view("ls", o).numbers == [1, 2, 3])
    }

    @Test func nlOutputIsStrippedAndKeepsItsOwnNumbers() {
        let o = ["     1\tdef f():", "     2\t    return 1", "      ", "     4\tx = 2"]
        let v = ToolBodies.shellOutputView(command: "nl x.py", output: o)
        #expect(v.lines == ["def f():", "    return 1", "", "x = 2"])
        #expect(v.numbers == [1, 2, nil, 4])
        #expect(v.plan == [OutputSection(lines: 0..<4, language: .python)])
    }

    // MARK: fix round 2

    @Test func coloursFollowALightDarkSwitch() async throws {
        let py = "def greet(name):\n    return \"hello \" + name\n"
        let window = try await shell(id: "sch", command: "cat src/x.py", out: py)
        try await waitForColours(window, in: "code-sch-output", atLeast: 2)
        let light = try colours(window, in: "code-sch-output")
        window.platformWindow.simulateAppearanceChange(to: .dark)
        try await window.runUntil {
            guard let now = try? colours(window, in: "code-sch-output") else { return false }
            return now.count >= 2 && now.isDisjoint(with: light)
        }
        window.platformWindow.simulateAppearanceChange(to: .light)
        try await window.runUntil { (try? colours(window, in: "code-sch-output")) == light }
    }

    @Test func itemsKeepAtMostTheRenderableLinesButAllOfTheText() {
        let lines = (1...2000).map { CodeLine(text: "l" + String($0), number: $0) }
        let item = CodeBlockItem(fingerprint: 1, lines: lines, plan: [])
        #expect(item.lines.count == ChatCodeBlock.maxRows + 1)
        #expect(item.total == 2000)
        #expect(item.fullText == (1...2000).map { "l\($0)" }.joined(separator: "\n"))
        #expect(item.gutterDigits == 4)
    }

    @Test func storeDropsItemsOfBlocksThatLeftTheTranscript() {
        let store = CodeBlockStore()
        let a = store.item(id: "a-1-output", fingerprint: 1) { ([], []) }
        let b = store.item(id: "b-2-command", fingerprint: 1) { ([], []) }
        store.prune(keepingBlockIDs: ["a-1"])
        #expect(store.item(id: "a-1-output", fingerprint: 1) { ([], []) } === a)
        #expect(store.item(id: "b-2-command", fingerprint: 1) { ([], []) } !== b)
    }

    @Test func derivedValuesAreBuiltOncePerKey() {
        let store = CodeBlockStore()
        var builds = 0
        func get(_ key: Int) -> Int { store.memo("t-shell", key: key) { builds += 1; return key * 10 } }
        #expect(get(1) == 10 && get(1) == 10 && builds == 1)
        #expect(get(2) == 20 && builds == 2)
    }

    // MARK: pure helpers

    @Test func singleFileCommandsColourTheirOutput() {
        let py = ["x = 1"]
        func plan(_ c: String, _ out: [String] = py) -> OutputColouring { ToolBodies.outputColouring(command: c, output: out) }
        #expect(plan("cat src/x.py") == .file(.python))
        #expect(plan("head -n 20 src/x.swift") == .file(.swift))
        #expect(plan("tail -20 'a b/x.rs'") == .file(.rust))
        #expect(plan("sed -n '1,40p' lib/y.go") == .file(.go))
        #expect(plan("nl -ba src/x.py") == .file(.python))
        #expect(plan("ls src") == .plain)
        #expect(plan("cat notes.txt") == .plain)          // no known language
        #expect(plan("cat a.py b.py") == .plain)          // cat has no separators
        #expect(plan("cat src/*.py") == .plain)
        #expect(plan("cat x.py | head") == .plain)
        #expect(plan("cd src && cat x.py") == .plain)
        #expect(plan("sed 's/a/b/' x.py") == .plain)      // not sed -n
    }

    @Test func multiFileDumpsColourBySectionOnlyWhenUnambiguous() {
        let head = ["==> a.py <==", "x = 1", "", "==> b.swift <==", "let y = 2"]
        #expect(ToolBodies.outputColouring(command: "head -n 5 a.py b.swift", output: head)
                == .sections([OutputSection(lines: 0..<3, language: .python), OutputSection(lines: 3..<5, language: .swift)]))
        let eq = ["=== a.py", "x = 1", "=== notes.txt", "hello"]
        #expect(ToolBodies.outputColouring(command: "for f in a.py notes.txt; do echo \"=== $f\"; cat $f; done", output: eq)
                == .sections([OutputSection(lines: 0..<2, language: .python), OutputSection(lines: 2..<4, language: nil)]))
        // Headers the command could not have produced are just text.
        #expect(ToolBodies.outputColouring(command: "ls", output: eq) == .plain)
        #expect(ToolBodies.outputColouring(command: "echo hi", output: head) == .plain)
        // Output that does not start with a header is ambiguous.
        #expect(ToolBodies.outputColouring(command: "head a.py b.py", output: ["noise"] + head) == .plain)
    }

    @Test func readResultsStripCLIPrefixesAndKeepRealNumbers() {
        let structured = ToolBlock(toolUseID: "r", name: "Read", kind: .read, summary: "",
                                   result: .object(["file": .object(["content": .string("a\nb\n"), "startLine": .number(7)])]))
        #expect(ToolBodies.readCode(structured)?.lines == ["a", "b"] && ToolBodies.readCode(structured)?.start == 7)
        let flat = ToolBlock(toolUseID: "r", name: "Read", kind: .read, summary: "", resultText: "12\tfoo\n13\tbar")
        #expect(ToolBodies.readCode(flat)?.lines == ["foo", "bar"] && ToolBodies.readCode(flat)?.start == 12)
        let none = ToolBlock(toolUseID: "r", name: "Read", kind: .read, summary: "", resultText: "plain\ntext")
        #expect(ToolBodies.readCode(none)?.lines == ["plain", "text"] && ToolBodies.readCode(none)?.start == 1)
    }
}

@MainActor
private func settle(_ condition: @MainActor () -> Bool) async throws {
    for _ in 0..<20_000 {
        if condition() { return }
        await Task.yield()
    }
    Issue.record("timed out")
    throw CancellationError()
}
