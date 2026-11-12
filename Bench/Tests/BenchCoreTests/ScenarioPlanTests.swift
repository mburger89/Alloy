import Testing
import Foundation
import CryptoKit
import CoreGraphics
@testable import BenchDrivers
@testable import BenchCore
@testable import BenchScenarios

private let corpusDir = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    .appendingPathComponent("Corpus")

@Suite struct ScenarioPlanTests {
    @Test func planMarksUnsupportedAsNA() {
        let plan = Runner.plan(apps: [.delta], metrics: [.typingLatency, .startup])
        #expect(plan.count == 2)
        guard case .notApplicable(let why)? = plan[0].applicable else {
            Issue.record("typingLatency should be pre-filled n/a"); return
        }
        #expect(why.contains("Delta"))
        #expect(plan[1].applicable == nil)
    }

    @Test func corpusManifestMatches() throws {
        let manifest = try String(contentsOf: corpusDir.appendingPathComponent("MANIFEST.sha256"), encoding: .utf8)
        var checked = 0
        for line in manifest.split(separator: "\n") {
            let parts = line.components(separatedBy: "  ")
            #expect(parts.count == 2)
            let data = try Data(contentsOf: corpusDir.appendingPathComponent(parts[1]))
            let hex = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            #expect(hex == parts[0], "\(parts[1]) hash mismatch")
            checked += 1
        }
        #expect(checked == 3)
    }

    @Test func largeCorpusIs100kLines() throws {
        let text = try String(contentsOf: corpusDir.appendingPathComponent("large.rs"), encoding: .utf8)
        #expect(text.split(separator: "\n", omittingEmptySubsequences: false).count - 1 == 100_000)
    }

    @Test func corpusIsRustAndLineCountsMatchSpec() throws {
        let c = Corpus.default
        for p in [c.small, c.medium, c.large] { #expect(p.hasSuffix(".rs")) }
        let names = try FileManager.default.contentsOfDirectory(atPath: corpusDir.path).sorted()
        #expect(names == ["MANIFEST.sha256", "generate.swift", "large.rs", "medium.rs", "small.rs"])
        for (p, n) in [(c.small, 200), (c.medium, 5_000), (c.large, 100_000)] {
            let text = try String(contentsOfFile: p, encoding: .utf8)
            #expect(text.split(separator: "\n", omittingEmptySubsequences: false).count - 1 == n)
            #expect(text.filter { $0 == "{" }.count == text.filter { $0 == "}" }.count, "braces unbalanced in \(p)")
        }
    }

    @Test func corpusDefaultsPointAtFiles() {
        let c = Corpus.default
        for p in [c.small, c.medium, c.large] { #expect(FileManager.default.fileExists(atPath: p)) }
    }
}

@Suite struct CLIArgumentTests {
    @Test func bareDefaultsToZedAndDelta() throws {
        #expect(try CLIArguments.resolveApps(nil, alloyBuild: nil).map(\.id) == ["zed", "delta"])
    }
    @Test func alloyAddedOnlyWithBuildDir() throws {
        #expect(try CLIArguments.resolveApps(nil, alloyBuild: "/x").map(\.id) == ["zed", "delta", "alloy"])
    }
    @Test func explicitAlloyWithoutBuildFails() {
        #expect(throws: (any Error).self) { _ = try CLIArguments.resolveApps("zed,alloy", alloyBuild: nil) }
        #expect(throws: (any Error).self) { _ = try CLIArguments.resolveApps("bogus", alloyBuild: nil) }
    }
    @Test func metricsDefaultAndParse() throws {
        #expect(try CLIArguments.resolveMetrics(nil) == Metric.allCases)
        #expect(try CLIArguments.resolveMetrics("startup, memory") == [.startup, .memory])
        #expect(throws: (any Error).self) { _ = try CLIArguments.resolveMetrics("nope") }
    }
}

@Suite struct MeasurementTests {
    @Test func scrollSafetyGuardRunsEveryEventOrEverySecond() {
        #expect(ScrollFramesScenario.safetyCheckInterval >= 1 && ScrollFramesScenario.safetyCheckInterval <= 2)
    }

    @Test func scrollIntervalsAreTrimmedToThePostWindow() {
        let ms = DisplayScan.ticks(ms: 1)
        // frames at 0, 10, 20 (before the first post at 100), 110, 120, 130, 145 (<= last post 130 + period 16), 200 (after)
        let times: [UInt64] = [0, 10, 20, 110, 120, 130, 145, 200].map { $0 * ms }
        let iv = ScrollFramesScenario.intervals(changeTimes: times, firstPost: 100 * ms, lastPost: 130 * ms, periodTicks: 16 * ms)
        #expect(iv.count == 3)   // 110->120, 120->130, 130->145
        #expect(abs(iv[0] - 10) < 0.01 && abs(iv[2] - 15) < 0.01)
        #expect(ScrollFramesScenario.intervals(changeTimes: [], firstPost: 0, lastPost: 10, periodTicks: 1).isEmpty)
    }

    @Test func dropCounterCountsOnlyEvictions() {
        let c = DropCounter()
        let (stream, cont) = AsyncStream.makeStream(of: (hostTime: UInt64, image: CGImage).self, bufferingPolicy: .bufferingNewest(1))
        let img = CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue)!.makeImage()!
        for i in 0..<5 { c.record(cont.yield((hostTime: UInt64(i), image: img))) }
        #expect(c.value == 4)
        withExtendedLifetime(stream) {}
    }

    @Test func droppedFramesExcludeStartupAndLargeFileRuns() {
        #expect(droppedFramesFailure(0) == nil)
        #expect(droppedFramesFailure(3)?.description.contains("capture dropped frames") == true)
    }

    @Test func cachedBaselineSignaturesGiveTheSameFraction() throws {
        func px(_ rows: Int) throws -> FrameDiff.Pixels {
            let ctx = CGContext(data: nil, width: 120, height: 100, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue)!
            ctx.setFillColor(CGColor(gray: 1, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: 120, height: 100))
            ctx.setFillColor(CGColor(gray: 0, alpha: 1))
            for y in 0..<rows { for x in stride(from: 0, to: 120, by: 6) { ctx.fill(CGRect(x: x, y: y, width: 2, height: 1)) } }
            return try #require(FrameDiff.crop(ctx.makeImage()!, to: PixelRect(x: 0, y: 0, width: 120, height: 100)))
        }
        let base = try px(20), cur = try px(60)
        let direct = FrameDiff.textRowFraction(cur, differingFrom: base)
        let sigs = FrameDiff.rowSignatures(base)
        #expect(FrameDiff.textRowFraction(cur, differingFrom: sigs) == direct)
        #expect(FrameDiff.textRowFraction(cur, differingFrom: sigs) == direct)   // reusable
        #expect(direct > 0 && direct < 0.6)
    }
}
