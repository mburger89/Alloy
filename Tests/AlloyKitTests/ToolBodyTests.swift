import AlloyCore
@testable import AlloyKit
import AlloyTestSupport
import Foundation
import MetalUI
import MetalUITesting
import Testing

@MainActor
@Suite struct ToolBodyTests {
    /// Runs one tool call through a session and renders it. `open` clicks the header of a collapsed-by-default block.
    private func render(name: String, id: String, input: JSONValue, text: String, raw: JSONValue?, isError: Bool = false,
                        open: Bool = false) async throws -> (TestWindow, Session) {
        let rig = Rig()
        rigs.append(rig)
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
    private let rigs = RigKeeper()

    private func tool(_ session: Session) -> ToolBlock? {
        for b in session.transcript.blocks { if case .tool(let t) = b { return t } }
        return nil
    }

    @Test func shellShowsCommandAndDuration() async throws {
        // Shape from a real Bash capture (ccprobe3 p6a.log), with stdout and stderr filled in.
        let raw: JSONValue = .object(["stdout": .string("one\ntwo\n"), "stderr": .string("warn\n"), "interrupted": .bool(false),
                                      "isImage": .bool(false), "noOutputExpected": .bool(false)])
        let (window, session) = try await render(name: "Bash", id: "b1", input: .object(["command": .string("ls -la"), "description": .string("List")]),
                                                 text: "one\ntwo\nwarn", raw: raw)
        try await window.runUntil { (try? window.element(label: "ls -la")) != nil }
        #expect((try? window.element(label: "one")) != nil && (try? window.element(label: "two")) != nil)
        #expect((try? window.element(label: "warn")) != nil)
        let t = try #require(tool(session))
        var done = t
        done.startedAt = Date(timeIntervalSince1970: 100); done.endedAt = Date(timeIntervalSince1970: 101.24)
        #expect(ToolBodies.trailing(for: done) == "1.2 s")
        done.endedAt = Date(timeIntervalSince1970: 100.01)
        #expect(ToolBodies.trailing(for: done) == "0.1 s")
        done.result = .object(["stdout": .string(""), "stderr": .string(""), "interrupted": .bool(true)])
        #expect(ToolBodies.trailing(for: done) == "0.1 s \u{00B7} interrupted")
    }

    @Test func shellOutputCollapsesToSixLinesBehindTheEye() async throws {
        let out = (1...30).map { "line \($0)" }.joined(separator: "\n") + "\n"
        let raw: JSONValue = .object(["stdout": .string(out), "stderr": .string(""), "interrupted": .bool(false)])
        let (window, _) = try await render(name: "Bash", id: "b2", input: .object(["command": .string("seq 30")]), text: out, raw: raw)
        try await window.runUntil { (try? window.element(identifier: "code-toggle-b2-output")) != nil }
        #expect((try? window.element(label: "line 6")) != nil)
        #expect((try? window.element(label: "line 7")) == nil)
        try window.click(window.element(identifier: "code-toggle-b2-output"))
        try await window.runUntil { (try? window.element(label: "line 30")) != nil }
        #expect(try window.element(identifier: "code-toggle-b2-output").label == "Show less")
    }

    @Test func readSummaryCountsLines() async throws {
        // Shape from a real Read capture (ccprobe3 p3.log).
        let raw: JSONValue = .object(["type": .string("text"), "file": .object([
            "filePath": .string("/x/greet.py"), "content": .string("def greet(name):\n    return \"hello \" + name\n"),
            "numLines": .number(3), "startLine": .number(1), "totalLines": .number(3)])])
        let (window, session) = try await render(name: "Read", id: "r1", input: .object(["file_path": .string("/x/greet.py")]),
                                                 text: "1\tdef greet(name):", raw: raw, open: true)
        #expect(try #require(tool(session)).summary == "/x/greet.py \u{00B7} 3 lines")
        try await window.runUntil { (try? window.element(label: "def greet(name):")) != nil }
        #expect((try? window.element(label: "    return \"hello \" + name")) != nil)
        // Numbering starts at startLine.
        let lines = (10...59).map { "l\($0)" }.joined(separator: "\n")
        var tool = ToolBlock(toolUseID: "r2", name: "Read", kind: .read, summary: "",
                             result: .object(["file": .object(["content": .string(lines), "startLine": .number(10)])]))
        let code = try #require(ToolBodies.readCode(tool))
        #expect(code.start == 10 && code.lines.first == "l10" && code.lines.count == 50)
        tool.result = .string("Error")
        #expect(ToolBodies.readCode(tool) == nil)
    }

    @Test func searchListsRelativeResultLines() async throws {
        // Shape from the CLI's Grep output schema (no live capture exists).
        let root = URL(fileURLWithPath: "/proj")
        let t = ToolBlock(toolUseID: "s1", name: "Grep", kind: .search, summary: "",
                          result: .object(["mode": .string("files_with_matches"), "numFiles": .number(2),
                                           "filenames": .array([.string("/proj/a/x.swift"), .string("/elsewhere/y.swift")])]))
        #expect(ToolBodies.searchLines(t, root: root) == ["a/x.swift", "/elsewhere/y.swift"])
        let many = ToolBlock(toolUseID: "s2", name: "Glob", kind: .search, summary: "",
                             result: .object(["filenames": .array((0..<80).map { .string("/proj/f\($0)") })]))
        #expect(ToolBodies.searchLines(many, root: root).count == 80)
    }

    @Test func todoRendersChecklist() async throws {
        // TodoWrite input shape from the CLI's schema (content, status, activeForm).
        func todo(_ c: String, _ s: String) -> JSONValue { .object(["content": .string(c), "status": .string(s), "activeForm": .string(c)]) }
        let input: JSONValue = .object(["todos": .array([todo("Write tests", "completed"), todo("Implement", "in_progress"), todo("Ship", "pending")])])
        let (window, _) = try await render(name: "TodoWrite", id: "t1", input: input, text: "Todos have been modified successfully.",
                                           raw: .object(["oldTodos": .array([]), "newTodos": input["todos"] ?? .null]), open: true)
        try await window.runUntil { (try? window.element(label: "\u{2713} Write tests")) != nil }
        #expect((try? window.element(label: "\u{25CF} Implement")) != nil)
        #expect((try? window.element(label: "\u{25CB} Ship")) != nil)
    }

    @Test func failedToolUsesErrorKind() async throws {
        // A failed Bash result is a plain string (ccprobe3 p3.log).
        let text = "Exit code 1\nls: nope: No such file or directory"
        let (window, session) = try await render(name: "Bash", id: "f1", input: .object(["command": .string("ls nope")]), text: text,
                                           raw: .string("Error: " + text), isError: true)
        try await window.runUntil { (try? window.element(label: "ls: nope: No such file or directory")) != nil }
        #expect((try? window.element(label: "ls nope")) != nil)
        let failed = try #require(tool(session))
        #expect(failed.status == .failed)
        #expect(ToolBodies.chromeKind(failed) == .error)
        #expect(BlockStyle.style(ToolBodies.chromeKind(failed)).icon == BlockStyle.style(.error).icon)
        var ok = failed
        ok.status = .succeeded
        #expect(ToolBodies.chromeKind(ok) == .shell)
    }

    @Test func mcpShowsPrettyInput() async throws {
        let input: JSONValue = .object(["to": .string("s2"), "text": .string("hi")])
        let (window, session) = try await render(name: "mcp__alloy__send_message", id: "m1", input: input, text: "ok", raw: nil, open: true)
        #expect(try #require(tool(session)).summary == "alloy \u{00B7} send_message")
        try await window.runUntil { (try? window.element(label: "{\n  \"text\" : \"hi\",\n  \"to\" : \"s2\"\n}")) != nil }
    }

    @Test func webSubagentAndPromptToggle() async throws {
        let (window, _) = try await render(name: "Agent", id: "a1",
                                           input: .object(["description": .string("Find it"), "prompt": .string("Look around")]),
                                           text: "Found it.", raw: nil)
        try await window.runUntil { (try? window.element(label: "Found it.")) != nil }
        #expect((try? window.element(label: "Look around")) == nil)
        try window.click(window.element(identifier: "prompt-toggle-a1"))
        try await window.runUntil { (try? window.element(label: "Look around")) != nil }
    }

    @Test func webShowsFirstTwentyLines() async throws {
        let text = (1...25).map { "w\($0)" }.joined(separator: "\n")
        let (window, _) = try await render(name: "WebFetch", id: "w1", input: .object(["url": .string("https://a.b")]), text: text,
                                           raw: nil, open: true)
        try await window.runUntil { (try? window.element(label: (1...20).map { "w\($0)" }.joined(separator: "\n"))) != nil }
        #expect((try? window.element(label: "\u{2026} 5 more lines")) != nil)
    }
}

extension ToolBodyTests {
    private func shellTool(_ status: ToolBlock.Status, result: JSONValue?, text: String) -> ToolBlock {
        ToolBlock(toolUseID: "x", name: "Bash", kind: .shell, summary: "", status: status, resultText: text,
                  input: .object(["command": .string("rm x")]),
                  startedAt: Date(timeIntervalSince1970: 100), endedAt: Date(timeIntervalSince1970: 101), result: result)
    }

    @Test func deniedAndCancelledShellKeepStatusWord() {
        #expect(ToolBodies.trailing(for: shellTool(.denied, result: .string("Error: denied"), text: "denied")) == "Denied")
        #expect(ToolBodies.trailing(for: shellTool(.interrupted, result: .string("Error: aborted"), text: "aborted")) == "Interrupted")
        #expect(ToolBodies.trailing(for: shellTool(.failed, result: .string("Error: Exit code 1"), text: "x")) == "Failed")
        // A real Bash result object (ccprobe3 p6c.log shape) still gets a duration.
        let interrupted: JSONValue = .object(["stdout": .string(""), "stderr": .string(""), "interrupted": .bool(true)])
        #expect(ToolBodies.trailing(for: shellTool(.interrupted, result: interrupted, text: "")) == "1.0 s \u{00B7} interrupted")
        #expect(ToolBodies.trailing(for: shellTool(.succeeded, result: nil, text: "")) == "1.0 s")
        #expect(!ToolBodies.showsFailure(shellTool(.interrupted, result: interrupted, text: "")))
        #expect(ToolBodies.showsFailure(shellTool(.denied, result: .string("Error: denied"), text: "denied")))
        #expect(ToolBodies.showsFailure(shellTool(.interrupted, result: nil, text: "aborted")))
    }

    @Test func deniedShellRendersDenialAsError() async throws {
        let rig = Rig()
        rigs.append(rig)
        let session = await rig.workspace.newSession(name: "A")
        let t = rig.transports[0]
        let input: JSONValue = .object(["command": .string("rm x")])
        await t.emit(.assistantBlock(messageID: "m1", block: .toolUse(id: "d1", name: "Bash", input: input)))
        await t.emit(.controlRequest(ControlRequest(requestID: "q1", kind: .canUseTool(toolName: "Bash", input: input, description: nil,
                                                                                         toolUseID: "d1", suggestions: []))))
        let window = try alloyWindow(rig.workspace)
        try await window.runUntil { (try? window.element(identifier: "deny-q1")) != nil }
        try window.click(window.element(identifier: "deny-q1"))
        await t.emit(.toolResult(ToolResultMessage(toolUseID: "d1", isError: true, text: "Permission to use Bash has been denied",
                                                   result: .none, raw: .string("Error: Permission to use Bash has been denied"))))
        try await settle { session.transcript.blocks.contains { if case .tool(let b) = $0 { b.endedAt != nil } else { false } } }
        let denied = try #require(tool(session))
        #expect(denied.status == .denied)
        #expect(ToolBodies.showsFailure(denied))
        #expect(ToolBodies.trailing(for: denied) == "Denied")
        try await window.runUntil { (try? window.element(label: "Permission to use Bash has been denied")) != nil }
        #expect((try? window.element(identifier: "code-d1-command")) != nil)   // the permission card also says "rm x"
    }

    @Test func nilResultRendersForEveryKind() async throws {
        let cases: [(String, JSONValue, String)] = [
            ("Bash", .object(["command": .string("true")]), "true"),
            ("Read", .object(["file_path": .string("/x/a.py")]), "Read /x/a.py"),
            ("Grep", .object(["pattern": .string("foo")]), "Search foo"),
            ("WebFetch", .object(["url": .string("https://a.b")]), "Web https://a.b"),
            ("Agent", .object(["description": .string("D"), "prompt": .string("P")]), "Agent D"),
            ("TodoWrite", .object(["todos": .array([.object(["content": .string("Do it"), "status": .string("pending"), "activeForm": .string("Doing")])])]),
             "\u{25CB} Do it"),
            ("mcp__s__t", .object(["k": .string("v")]), "{\n  \"k\" : \"v\"\n}"),
        ]
        for (i, c) in cases.enumerated() {
            let rig = Rig()
            rigs.append(rig)
            let session = await rig.workspace.newSession(name: "A")
            await rig.transports[0].emit(.assistantBlock(messageID: "m1", block: .toolUse(id: "n\(i)", name: c.0, input: c.1)))
            try await settle { session.transcript.blocks.count == 1 }
            let window = try alloyWindow(rig.workspace)
            try await window.runUntil { (try? window.element(identifier: "block-header-n\(i)")) != nil }
            // Read, search, web, todo and mcp start collapsed; open them.
            if (try? window.element(label: c.2)) == nil, ["Read", "Grep", "WebFetch", "TodoWrite", "mcp__s__t"].contains(c.0) {
                try window.click(window.element(identifier: "block-header-n\(i)"))
                window.tick()
            }
            try await window.runUntil { (try? window.element(label: c.2)) != nil }
        }
    }

    @Test func mixedOutputGivesStdoutAndStderrTheirOwnBlocks() async throws {
        let out = (1...15).map { "o\($0)" }.joined(separator: "\n")
        let err = (1...15).map { "e\($0)" }.joined(separator: "\n")
        let raw: JSONValue = .object(["stdout": .string(out), "stderr": .string(err), "interrupted": .bool(false)])
        let (window, _) = try await render(name: "Bash", id: "c1", input: .object(["command": .string("x")]), text: out + "\n" + err, raw: raw)
        try await window.runUntil { (try? window.element(identifier: "code-toggle-c1-stderr")) != nil }
        #expect((try? window.element(identifier: "code-toggle-c1-output")) != nil)
        #expect((try? window.element(label: "o6")) != nil && (try? window.element(label: "o7")) == nil)
        try window.click(window.element(identifier: "code-toggle-c1-stderr"))
        try await window.runUntil { (try? window.element(label: "e15")) != nil }
        #expect((try? window.element(label: "o7")) == nil)   // stdout stayed collapsed
    }

    @Test func emptySearchFallsBackToResultText() {
        // An empty Glob result: no filenames, text "No files found".
        let t = ToolBlock(toolUseID: "g", name: "Glob", kind: .search, summary: "", resultText: "No files found",
                          result: .object(["numFiles": .number(0), "filenames": .array([])]))
        #expect(ToolBodies.searchLines(t, root: URL(fileURLWithPath: "/proj")) == ["No files found"])
    }
}

@MainActor
final class RigKeeper { var rigs: [Rig] = []; func append(_ r: Rig) { rigs.append(r) } }

@MainActor
private func settle(_ condition: @MainActor () -> Bool) async throws {
    for _ in 0..<20_000 {
        if condition() { return }
        await Task.yield()
    }
    Issue.record("timed out")
    throw CancellationError()
}