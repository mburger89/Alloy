import Foundation
import Testing
@testable import BenchCore

@Suite struct BenchPathsTests {
    private func makeRepo() throws -> String {
        let root = (NSTemporaryDirectory() as NSString).appendingPathComponent("benchpaths-\(UUID().uuidString)")
        try FileManager.default.createDirectory(atPath: root + "/Bench/Sources", withIntermediateDirectories: true)
        try "// swift-tools-version: 6.0\n".write(toFile: root + "/Bench/Package.swift", atomically: true, encoding: .utf8)
        return URL(fileURLWithPath: root).resolvingSymlinksInPath().path
    }

    @Test func findsBenchFromRepoRootBenchAndSubdirectory() throws {
        let root = try makeRepo()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let want = root + "/Bench/traces"
        #expect(BenchPaths.defaultDirectory("traces", cwd: root) == want)
        #expect(BenchPaths.defaultDirectory("traces", cwd: root + "/Bench") == want)
        #expect(BenchPaths.defaultDirectory("traces", cwd: root + "/Bench/Sources") == want)
        #expect(BenchPaths.defaultDirectory("results", cwd: root + "/Bench") == root + "/Bench/results")
    }

    @Test func fallsBackToRelativeWhenNoBenchPackage() throws {
        let dir = (NSTemporaryDirectory() as NSString).appendingPathComponent("benchpaths-none-\(UUID().uuidString)")
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        #expect(BenchPaths.defaultDirectory("results", cwd: dir) == "Bench/results")
    }
}
