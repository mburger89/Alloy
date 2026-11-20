import Foundation
import Testing

/// THIRD-PARTY-NOTICES.md carries a full licence per shipped component, and the bundler ships it.
@Suite struct NoticesTests {
    private static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    private func read(_ path: String) throws -> String {
        try String(contentsOf: Self.root.appendingPathComponent(path), encoding: .utf8)
    }

    private func count(_ needle: String, in text: String) -> Int { text.components(separatedBy: needle).count - 1 }

    @Test func everyShippedComponentHasASection() throws {
        let text = try read("THIRD-PARTY-NOTICES.md")
        let sections = text.split(separator: "\n").filter { $0.hasPrefix("## ") }.map(String.init)
        for name in ["Sparkle", "SwiftTreeSitter", "tree-sitter (runtime)", "MetalUI", "stb_image", "Lucide"]
            where !sections.contains(where: { $0.contains(name) }) {
            Issue.record("no section for \(name)")
        }
        for grammar in ["bash", "c", "cpp", "css", "go", "html", "javascript", "json", "markdown", "python", "rust", "swift",
                        "typescript", "yaml"]
            where !sections.contains(where: { $0.contains("tree-sitter-\(grammar) grammar") }) {
            Issue.record("no section for the \(grammar) grammar")
        }
        #expect(sections.count == 20)
    }

    @Test func licenceTextsAreIncludedInFull() throws {
        let text = try read("THIRD-PARTY-NOTICES.md")
        // MIT: Sparkle, tree-sitter, 13 MIT grammars (yaml included), MetalUI, stb_image, Feather.
        #expect(count("Permission is hereby granted", in: text) >= 18)
        #expect(count("Redistribution and use", in: text) >= 1)                    // SwiftTreeSitter (BSD 3-Clause)
        #expect(count("Permission to use, copy, modify, and/or distribute", in: text) >= 1)   // Lucide (ISC)
        #expect(text.contains("Unlicense") || text.contains("public domain"))        // stb_image alternative B
        #expect(text.contains("Sean Barrett"))
        #expect(text.contains("Andy Matuschak"))
    }

    @Test func containsNoPersonalData() throws {
        let text = try read("THIRD-PARTY-NOTICES.md")
        let pattern = try Regex(["max" + "burger", "/Us" + "ers/[A-Za-z]", "claude" + "-501", "claude\\.ai/code/" + "session", "com\\.max" + "burger", "mburger89" + "@gmail"].joined(separator: "|"))
        #expect(text.firstMatch(of: pattern) == nil)
    }

    @Test func bundlerShipsTheLicenceAndNoticesAndStripsBuildRpaths() throws {
        let script = try read("scripts/bundle-macos.sh")
        #expect(script.contains("THIRD-PARTY-NOTICES.md"))
        #expect(script.contains("Contents/Resources/LICENSE") || script.contains("\"$APP/Contents/Resources/\""))
        #expect(script.contains("strip_build_rpaths"))
        for prefix in ["/Applications", "/Library/Developer", "/var/run", "/Users"] { #expect(script.contains(prefix)) }
        #expect(script.contains("delete_rpath"))
    }

    /// Runs the bundler's strip routine, extracted from the script, on a copy of a system binary with an added rpath.
    @Test func stripRoutineRemovesBuildRpathsAndIsIdempotent() throws {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent("alloy-rpath-\(UUID().uuidString)")
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tmp) }
        let script = try read("scripts/bundle-macos.sh")
        let start = try #require(script.range(of: "# BEGIN strip_build_rpaths"))
        let end = try #require(script.range(of: "# END strip_build_rpaths"))
        let routine = String(script[start.upperBound..<end.lowerBound])
        let bin = tmp.appendingPathComponent("tool")
        try fm.copyItem(atPath: "/usr/bin/true", toPath: bin.path)
        func run(_ args: [String]) throws -> (Int32, String) {
            let p = Process(); p.executableURL = URL(fileURLWithPath: "/bin/sh"); p.arguments = args
            let out = Pipe(); p.standardOutput = out; p.standardError = out
            try p.run(); p.waitUntilExit()
            return (p.terminationStatus, String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))
        }
        // /usr/bin/true is a fat system binary and may be unmodifiable; link a tiny one instead when it is.
        let src = tmp.appendingPathComponent("t.c"); try "int main(void){return 0;}".write(to: src, atomically: true, encoding: .utf8)
        try fm.removeItem(at: bin)
        let (cc, ccOut) = try run(["-c", "cc -o '\(bin.path)' '\(src.path)' -Wl,-rpath,/Us" + "ers/someone/build -Wl,-rpath,/Library/Developer/x -Wl,-rpath,@executable_path/../Frameworks"])
        try #require(cc == 0, Comment(rawValue: ccOut))
        let driver = tmp.appendingPathComponent("drv.sh")
        try (routine + "\nstrip_build_rpaths '\(bin.path)'\n").write(to: driver, atomically: true, encoding: .utf8)
        for _ in 0..<2 {   // second run: nothing left to strip, must not fail
            let (status, out) = try run([driver.path])
            #expect(status == 0, Comment(rawValue: out))
        }
        let (_, otool) = try run(["-c", "otool -l '\(bin.path)' | grep -A2 LC_RPATH"])
        #expect(!otool.contains("/Us" + "ers/someone"))
        #expect(!otool.contains("/Library/Developer"))
        #expect(otool.contains("@executable_path/../Frameworks"))
    }
}
