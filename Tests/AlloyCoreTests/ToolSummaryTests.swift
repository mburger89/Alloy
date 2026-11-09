import AlloyCore
import Foundation
import Testing

@Suite struct ToolSummaryTests {
    let root = URL(fileURLWithPath: "/proj")
    func line(_ name: String, _ input: [String: JSONValue], _ result: JSONValue? = nil) -> String {
        ToolSummary.line(toolName: name, input: .object(input), projectRoot: root, result: result)
    }

    // Shape copied from a real Read capture (ccprobe3 p3.log).
    @Test func readCountsLines() {
        let result: JSONValue = .object(["type": .string("text"), "file": .object([
            "filePath": .string("/proj/greet.py"), "content": .string("def greet(name):\n    return \"hello \" + name\n"),
            "numLines": .number(3), "startLine": .number(1), "totalLines": .number(3)])])
        #expect(line("Read", ["file_path": .string("/proj/greet.py")], result) == "greet.py \u{00B7} 3 lines")
        #expect(line("Read", ["file_path": .string("/proj/greet.py")]) == "greet.py")
        // A failed read's result is a plain string.
        #expect(line("Read", ["file_path": .string("/proj/greet.py")], .string("Error: nope")) == "greet.py")
    }

    // Grep and Glob result shapes come from the CLI's output schema (no live capture exists).
    @Test func grepAndGlobCounts() {
        let files: JSONValue = .object(["mode": .string("files_with_matches"), "numFiles": .number(2),
                                        "filenames": .array([.string("/proj/a.swift"), .string("/proj/b.swift")])])
        let counts: JSONValue = .object(["mode": .string("count"), "numFiles": .number(2), "numMatches": .number(7)])
        let content: JSONValue = .object(["mode": .string("content"), "numFiles": .number(0), "numLines": .number(1),
                                          "content": .string("a.swift:3:foo")])
        #expect(line("Grep", ["pattern": .string("foo")], counts) == "\"foo\" \u{00B7} 7 matches")
        #expect(line("Grep", ["pattern": .string("foo")], content) == "\"foo\" \u{00B7} 1 match")
        #expect(line("Grep", ["pattern": .string("foo")], files) == "\"foo\" \u{00B7} 2 files")
        #expect(line("Grep", ["pattern": .string("foo")]) == "foo")
        let glob: JSONValue = .object(["durationMs": .number(4), "numFiles": .number(12), "filenames": .array([]), "truncated": .bool(false)])
        #expect(line("Glob", ["pattern": .string("**/*.swift")], glob) == "**/*.swift \u{00B7} 12 files")
        #expect(line("Glob", ["pattern": .string("**/*.swift")]) == "**/*.swift")
    }

    @Test func mcpNamesServerAndTool() {
        #expect(line("mcp__alloy__send_message", [:]) == "alloy \u{00B7} send_message")
        #expect(line("mcp__a__b__c", [:]) == "a \u{00B7} b__c")
    }

    @Test func resultUpdatesTranscriptSummary() {
        var t = Transcript(projectRoot: root)
        t.apply(.assistantBlock(messageID: "m1", block: .toolUse(id: "g1", name: "Glob", input: .object(["pattern": .string("*.py")]))))
        t.apply(.toolResult(ToolResultMessage(toolUseID: "g1", isError: false, text: "x.py", result: .none,
                                              raw: .object(["numFiles": .number(1), "filenames": .array([.string("/proj/x.py")])]))))
        guard case .tool(let tool) = t.blocks[0] else { Issue.record("no tool"); return }
        #expect(tool.summary == "*.py \u{00B7} 1 file")
    }
}
