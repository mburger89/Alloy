@testable import AlloyCore
import Foundation
import Testing

@Suite struct FileWatcherTests {
    @Test func ignoredDirectories() {
        #expect(FSEventsSource.isIgnored("/p/.build/debug/x.o", root: "/p"))
        #expect(FSEventsSource.isIgnored("/p/web/node_modules/a/index.js", root: "/p"))
        #expect(FSEventsSource.isIgnored("/p/.swiftpm/xcode/x", root: "/p"))
        #expect(!FSEventsSource.isIgnored("/p/Sources/a.swift", root: "/p"))
        #expect(!FSEventsSource.isIgnored("/p/.git/HEAD", root: "/p"))
        #expect(!FSEventsSource.isIgnored("/p/build/a.swift", root: "/p"))
        // Only the part below the root counts: a project that itself lives under node_modules still reports.
        #expect(!FSEventsSource.isIgnored("/w/node_modules/p/Sources/a.swift", root: "/w/node_modules/p"))
        #expect(FSEventsSource.isIgnored("/w/node_modules/p/.build/x", root: "/w/node_modules/p"))
    }

    @Test(.timeLimit(.minutes(1))) func projectUnderNodeModulesStillReports() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("alloy-fs-\(UUID().uuidString)")
        let dir = base.appendingPathComponent("node_modules/proj")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let target = URL(fileURLWithPath: FSEventsSource.realPath(dir)).appendingPathComponent("a.txt").path
        let stream = FSEventsSource(root: dir, latency: 0.1).changes()
        let written = dir.appendingPathComponent("a.txt").path
        let seen = await withTaskGroup(of: (String, Bool).self) { group in
            group.addTask {
                for await paths in stream where paths.contains(target) { return ("reader", true) }
                return ("reader", false)
            }
            group.addTask {
                for _ in 0..<40 {
                    if Task.isCancelled { break }
                    try? "x\(UUID())".write(toFile: written, atomically: true, encoding: .utf8)
                    try? await Task.sleep(for: .milliseconds(50))
                }
                return ("writer", false)
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(2))
                return ("limit", false)
            }
            var result = false
            for await (who, ok) in group where who != "writer" { result = ok; break }
            group.cancelAll()
            return result
        }
        #expect(seen)
    }

    @Test(.timeLimit(.minutes(1))) func fsEventsIntegration() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("alloy-fs-\(UUID().uuidString)")
        let dir = base.appendingPathComponent("p")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        // The root is given in its /var form; events carry the real /private/var path.
        let target = URL(fileURLWithPath: FSEventsSource.realPath(dir)).appendingPathComponent("a.txt").path
        let stream = FSEventsSource(root: dir, latency: 0.1).changes()
        let written = dir.appendingPathComponent("a.txt").path
        let seen = await withTaskGroup(of: (String, Bool).self) { group in
            group.addTask {
                for await paths in stream where paths.contains(target) { return ("reader", true) }
                return ("reader", false)
            }
            group.addTask {
                // Writes repeatedly until the stream is up: FSEvents only reports changes after it started.
                for _ in 0..<40 {
                    if Task.isCancelled { break }
                    try? "x\(UUID())".write(toFile: written, atomically: true, encoding: .utf8)
                    try? await Task.sleep(for: .milliseconds(50))
                }
                return ("writer", false)
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(2))
                return ("limit", false)
            }
            var result = false
            for await (who, ok) in group where who != "writer" { result = ok; break }
            group.cancelAll()
            return result
        }
        #expect(seen)
    }
}
