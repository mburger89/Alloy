import AlloyCore
@testable import AlloyPlugins
import Foundation
import Testing

@Suite struct PluginDecorationParseTests {
    private func params(_ items: String, version: Int = 3) -> JSONValue {
        JSONValue.parse(Data(#"{"uri":"file:///p/a.swift","version":\#(version),"items":\#(items)}"#.utf8)) ?? .null
    }

    @Test func parsesLineAndRangeItems() throws {
        let parsed = try #require(PluginDecorationSet.parse(params("""
        [{"line":2,"background":"info","gutterBar":"warning","marker":{"text":"!","role":"error"},"message":{"text":"careful","role":"muted"}},
         {"line":4,"endLine":6,"background":"success"},
         {"start":3,"end":9,"underline":"error","tint":"accent"}]
        """), cap: 500))
        #expect(parsed.uri == "file:///p/a.swift")
        #expect(parsed.set.version == 3)
        #expect(parsed.set.lines.count == 2 && parsed.set.ranges.count == 1)
        let first = parsed.set.lines[0]
        #expect(first.line == 2 && first.endLine == nil)
        #expect(first.background == .info && first.gutterBar == .warning)
        #expect(first.marker == .init(text: "!", role: .error) && first.message == .init(text: "careful", role: .muted))
        #expect(parsed.set.lines[1].endLine == 6)
        #expect(parsed.set.ranges[0] == .init(start: 3, end: 9, underline: .error, tint: .accent))
    }

    @Test func capKeepsFirst500() throws {
        let items = (0..<600).map { #"{"line":\#($0),"background":"info"}"# }.joined(separator: ",")
        let parsed = try #require(PluginDecorationSet.parse(params("[\(items)]"), cap: 500))
        #expect(parsed.set.lines.count == 500)
        #expect(parsed.set.lines.last?.line == 499)
        // Lines come before ranges when both exceed the cap.
        let mixed = (0..<300).map { #"{"line":\#($0),"background":"info"},{"start":\#($0),"end":\#($0 + 1),"tint":"info"}"# }.joined(separator: ",")
        let both = try #require(PluginDecorationSet.parse(params("[\(mixed)]"), cap: 500))
        #expect(both.set.lines.count == 300 && both.set.ranges.count == 200)
    }

    @Test func outOfRangeItemsAreDroppedOthersPaint() throws {
        let parsed = try #require(PluginDecorationSet.parse(params("""
        [{"line":-1,"background":"info"},
         {"line":1,"background":"info"},
         {"line":2,"background":"purple"},
         {"start":9,"end":3,"underline":"error"},
         {"start":-2,"end":3,"underline":"error"},
         {"line":3,"endLine":3,"background":"info"},
         {"start":1,"end":4,"underline":"error"}]
        """), cap: 500))
        #expect(parsed.set.lines.map(\.line) == [1])
        #expect(parsed.set.ranges == [.init(start: 1, end: 4, underline: .error)])
    }

    @Test func markerLongerThanTwoCharsIsDropped() throws {
        let parsed = try #require(PluginDecorationSet.parse(params("""
        [{"line":0,"marker":{"text":"abc","role":"info"}},
         {"line":1,"marker":{"text":"ab","role":"info"}},
         {"line":2,"marker":{"text":"","role":"info"}}]
        """), cap: 500))
        #expect(parsed.set.lines.map(\.line) == [1])
    }

    @Test func messageIsOneLineOfAtMost200Characters() throws {
        let long = String(repeating: "x", count: 300)
        let parsed = try #require(PluginDecorationSet.parse(params(#"[{"line":0,"message":{"text":"first\nsecond","role":"info"}},{"line":1,"message":{"text":"\#(long)","role":"info"}}]"#), cap: 500))
        #expect(parsed.set.lines[0].message?.text == "first")
        #expect(parsed.set.lines[1].message?.text.count == 200)
    }

    @Test func paramsWithoutUriVersionOrItemsAreRejected() {
        #expect(PluginDecorationSet.parse(.object(["version": .number(1), "items": .array([])]), cap: 500) == nil)
        #expect(PluginDecorationSet.parse(.object(["uri": .string("file:///a"), "items": .array([])]), cap: 500) == nil)
        #expect(PluginDecorationSet.parse(.object(["uri": .string("file:///a"), "version": .number(1)]), cap: 500) == nil)
    }
}
