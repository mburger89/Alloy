import Foundation
import Testing
@testable import BenchCore

@Suite struct HotspotsTests {
    static func fixture(_ name: String) -> URL {
        Bundle.module.resourceURL!.appendingPathComponent("Fixtures/\(name)")
    }
    static func data(_ name: String) throws -> Data { try Data(contentsOf: fixture(name)) }

    /// A fake `xcrun` that cats fixtures: `--toc` gets `toc`, an xpath naming a schema gets `table`.
    static func fakeXcrun(toc: String, table: String, tableBody: String? = nil) throws -> String {
        let path = try writeScript("""
        for a in "$@"; do
          if [ "$a" = "--toc" ]; then cat "\(fixture(toc).path)"; exit 0; fi
        done
        \(tableBody ?? "cat \"\(fixture(table).path)\"")
        """)
        return path
    }

    static func writeScript(_ body: String) throws -> String {
        let dir = NSTemporaryDirectory() + "hotspots-fake-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let path = dir + "/xcrun"
        let script = "#!/bin/bash\n" + body
        try script.write(toFile: path, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
        return path
    }

    static func remove(_ script: String) {
        try? FileManager.default.removeItem(atPath: (script as NSString).deletingLastPathComponent)
    }

    @Test func timeProfileRanksBySelfSamples() throws {
        let rows = Hotspots.timeProfile(xml: try Self.data("time-profile.xml"), top: 3)
        #expect(rows.map(\.name) == ["HighlightCore.parse", "CodeBuffer.insert", "Layout.measure"])
        #expect(rows.map(\.selfValue) == [11, 6, 4])
        #expect(rows.map(\.totalValue) == [11, 20, 4])
        #expect(rows[0].unit == "samples")
        #expect(rows[0].selfMs == 11)
    }

    @Test func refsAreResolved() throws {
        // `Layout.measure` frames repeat `CodeBuffer.insert` and `main` only as <frame ref>, and most
        // stacks are <backtrace ref>: totals only add up when refs resolve to the named element.
        let all = Hotspots.timeProfile(xml: try Self.data("time-profile.xml"), top: 10)
        let main = try #require(all.first { $0.name == "main" })
        #expect(main.selfValue == 2)
        #expect(main.totalValue == 23)
        #expect(all.count == 4)
    }

    @Test func realFormatTaggedBacktraceRows() throws {
        // Trimmed from a real export: <tagged-backtrace> with direct <frame> children, one row that is only
        // <tagged-backtrace ref>, one <sentinel/> stack, and frames shared by ref.
        let rows = Hotspots.timeProfile(xml: try Self.data("time-profile-tagged.xml"), top: 10)
        #expect(rows.map(\.name) == ["Layout.measure(_:)", "HighlightCore.parse(_:)", "CodeBuffer.insert(_:at:)", "main"])
        #expect(rows.map(\.selfValue) == [3, 1, 0, 0])
        #expect(rows.map(\.totalValue) == [3, 1, 4, 4])
        #expect(rows[0].selfMs == 3)
    }

    @Test func allocationsRanksByLiveBytes() throws {
        let rows = Hotspots.allocations(xml: try Self.data("allocations.xml"), top: 3)
        #expect(rows.map(\.name) == ["HighlightCore.parse", "CodeBuffer.insert", "Layout.measure"])
        #expect(rows.map(\.selfValue) == [1000, 300, 0])
        #expect(rows.map(\.totalValue) == [5000, 400, 8000])
        #expect(rows[0].unit == "bytes")
    }

    @Test func emptyTableIsReported() throws {
        let fake = try Self.fakeXcrun(toc: "toc-time.xml", table: "time-profile-empty.xml")
        defer { Self.remove(fake) }
        let text = try Hotspots.report(trace: "/home/tester/alloy-time.trace", top: 25, executable: fake)
        #expect(text.contains("no samples in time-profile: the app was not on the CPU while recording (an idle app records nothing)"))
        #expect(!text.contains("no rows"))
    }

    @Test func reportRendersTimeAndAllocations() throws {
        let f1 = try Self.fakeXcrun(toc: "toc-time.xml", table: "time-profile.xml")
        let f2 = try Self.fakeXcrun(toc: "toc-alloc.xml", table: "allocations.xml")
        defer { Self.remove(f1); Self.remove(f2) }
        let t = try Hotspots.report(trace: "/home/tester/alloy-cpu.trace", top: 2, executable: f1)
        #expect(t.contains("By self samples") && t.contains("By total samples") && t.contains("HighlightCore.parse"))
        let a = try Hotspots.report(trace: "/home/tester/alloy-memory.trace", top: 2,
            executable: f2)
        #expect(a.contains("By bytes still live") && a.contains("Layout.measure"))
    }

    @Test func missingColumnsAreReported() throws {
        let fake = try Self.fakeXcrun(toc: "toc-alloc.xml", table: "time-profile.xml")
        defer { Self.remove(fake) }
        let text = try Hotspots.report(trace: "/home/tester/x.trace", top: 5, executable: fake)
        #expect(text.contains("no rows in allocations"))
    }

    @Test func unknownKindListsTOC() throws {
        let fake = try Self.fakeXcrun(toc: "toc-hitches.xml", table: "time-profile-empty.xml")
        defer { Self.remove(fake) }
        let text = try Hotspots.report(trace: "/home/tester/alloy-frames.trace", top: 25, executable: fake)
        #expect(text.contains("- hitches"))
        #expect(text.contains("- hitches-frame-lifetimes"))
        #expect(text.contains("Open the trace in Instruments"))
    }

    @Test func exportTimesOut() throws {
        let fake = try Self.writeScript("exec sleep 30")
        defer { Self.remove(fake) }
        let start = Date()
        #expect(throws: Hotspots.Failure.self) {
            try Hotspots.report(trace: "/home/tester/x.trace", top: 5, executable: fake, timeout: 1)
        }
        #expect(Date().timeIntervalSince(start) < 10)
        do { _ = try Hotspots.report(trace: "/home/tester/x.trace", top: 5, executable: fake, timeout: 1) }
        catch { #expect("\(error)" == "xctrace export timed out after 1 s") }
    }

    @Test func failureIncludesStderrFirstLine() throws {
        let fake = try Self.writeScript("echo 'Document Missing Template Error' >&2; echo second >&2; exit 3")
        defer { Self.remove(fake) }
        do { _ = try Hotspots.report(trace: "/home/tester/x.trace", top: 5, executable: fake); Issue.record("no throw") }
        catch { #expect("\(error)" == "xctrace export failed (exit 3): Document Missing Template Error") }
    }

    @Test func truncatedXMLIsAParseFailure() throws {
        let fake = try Self.fakeXcrun(toc: "toc-time.xml", table: "", tableBody: "echo '<trace-query-result><node><schema name=\"time-profile\">'")
        defer { Self.remove(fake) }
        do { _ = try Hotspots.report(trace: "/home/tester/x.trace", top: 5, executable: fake); Issue.record("no throw") }
        catch { #expect("\(error)" == "could not parse xctrace export for time-profile") }
    }

    @Test func nonFiniteValuesAreDropped() {
        let xml = """
        <r><node><schema name="allocations"><col><mnemonic>size</mnemonic></col><col><mnemonic>live</mnemonic></col>\
        <col><mnemonic>responsible-caller</mnemonic></col></schema>\
        <row><size>nan</size><live>1</live><frame name="A"/></row>\
        <row><size>inf</size><live>1</live><frame name="A"/></row>\
        <row><size>5</size><live>1</live><frame name="B"/></row></node></r>
        """
        let rows = Hotspots.allocations(xml: Data(xml.utf8), top: 5)
        #expect(rows.map(\.name) == ["B"])
    }

    @Test func refCyclesTerminate() {
        let xml = """
        <r><node><schema name="time-profile"><col><mnemonic>stack</mnemonic></col></schema>\
        <row><backtrace id="1"><frame id="2" name="F"/><backtrace ref="1"/></backtrace></row>\
        <row><backtrace id="3"><backtrace ref="3"/></backtrace></row></node></r>
        """
        let rows = Hotspots.timeProfile(xml: Data(xml.utf8), top: 5)
        #expect(rows.map(\.name) == ["F"])
    }

    @Test func trailingSlashWritesSiblingMarkdown() {
        #expect(Hotspots.markdownPath(forTrace: "/home/tester/foo.trace/") == "/home/tester/foo.trace.md")
        #expect(Hotspots.markdownPath(forTrace: "/home/tester/foo.trace") == "/home/tester/foo.trace.md")
    }
}
