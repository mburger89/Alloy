import CoreGraphics
import Testing
@testable import BenchCore
@testable import BenchDrivers
@testable import BenchScenarios

@Suite struct WindowCoverTests {
    let display = CGRect(x: 0, y: 0, width: 2000, height: 1000)   // central region: 400..1600 x 200..800
    func win(_ name: String, pid: Int32 = 10, layer: Int = 0, _ r: CGRect, alpha: Double = 1) -> WindowDescriptor {
        WindowDescriptor(ownerName: name, pid: pid, layer: layer, bounds: r, alpha: alpha)
    }

    @Test func centralRegionIs60By60() {
        #expect(WindowCover.centralRegion(of: display) == CGRect(x: 400, y: 200, width: 1200, height: 600))
    }

    @Test func fullScreenTerminalCovers() {
        let c = WindowCover.covers(windows: [win("Ghostty", display)], display: display)
        #expect(c.count == 1 && c[0].ownerName == "Ghostty" && abs(c[0].fraction - 1) < 1e-9)
    }

    @Test func belowThresholdIsIgnoredAboveCounts() {
        // Region area 720_000; 10 % = 72_000. 300x200 = 60_000 (8.3 %) vs 400x200 = 80_000 (11.1 %).
        #expect(WindowCover.covers(windows: [win("A", CGRect(x: 400, y: 200, width: 300, height: 200))], display: display).isEmpty)
        #expect(WindowCover.covers(windows: [win("A", CGRect(x: 400, y: 200, width: 400, height: 200))], display: display).count == 1)
    }

    @Test func outsideTheCentralRegionIsIgnored() {
        #expect(WindowCover.covers(windows: [win("Dock-ish", CGRect(x: 0, y: 900, width: 2000, height: 100))], display: display).isEmpty)
        #expect(WindowCover.covers(windows: [win("Left", CGRect(x: 0, y: 0, width: 400, height: 1000))], display: display).isEmpty)
    }

    @Test func nonNormalLayersAndInvisibleWindowsAreIgnored() {
        #expect(WindowCover.covers(windows: [win("Ollama menu", layer: 101, display)], display: display).isEmpty)
        #expect(WindowCover.covers(windows: [win("Ghost", display, alpha: 0)], display: display).isEmpty)
    }

    @Test func excludedPidsAreIgnoredButOthersAreNot() {
        let ws = [win("Zed", pid: 5, display), win("Terminal", pid: 6, display)]
        let c = WindowCover.covers(windows: ws, display: display, excluding: [5])
        #expect(c.map(\.ownerName) == ["Terminal"])
    }

    @Test func sortedLargestFirstOnePerPid() {
        let ws = [win("Small", pid: 1, CGRect(x: 400, y: 200, width: 600, height: 300)),
                  win("Small", pid: 1, CGRect(x: 400, y: 200, width: 500, height: 300)),
                  win("Big", pid: 2, CGRect(x: 400, y: 200, width: 1200, height: 600))]
        let c = WindowCover.covers(windows: ws, display: display)
        #expect(c.map(\.ownerName) == ["Big", "Small"])
    }

    @Test func refusalNamesTheOwnerAndTheAdvice() {
        let c = WindowCover.covers(windows: [win("Ghostty", display)], display: display)
        let m = WindowCover.refusalMessage(c, targetName: "Zed")
        #expect(m?.contains("Ghostty") == true)
        #expect(m?.contains("move or minimize it (the harness never moves other apps' windows)") == true
                || m?.contains("Move or minimize it (the harness never moves other apps' windows)") == true)
        #expect(WindowCover.refusalMessage([], targetName: "Zed") == nil)
    }

    @Test func paintFailuresGetCoveredByAppended() {
        let c = WindowCover.covers(windows: [win("Ghostty", display)], display: display)
        for r in ["text not painted within 30 s", "fewer than 2 changed frames while scrolling",
                  "window on screen but no paint detected within 30 s", "no frame change"] {
            #expect(WindowCover.annotate(r, covers: c) == r + " (covered by Ghostty)")
        }
        #expect(WindowCover.annotate("no window within 30 s", covers: c) == "no window within 30 s")
        #expect(WindowCover.annotate("text not painted", covers: []) == "text not painted")
    }

    @Test func runnerRefusesAnAppWhoseWindowsWouldBeCoveredBeforeLaunching() async throws {
        let app = TargetApp(id: "t", displayName: "T", bundlePath: nil, executablePath: "/nonexistent", launchArguments: { _ in [] })
        do {
            _ = try await Runner.run(apps: [app], metrics: [.startup], corpus: .default, runsOverride: 1,
                                     preflight: { _ in nil }, coverCheck: { _ in "Ghostty covers it" })
            Issue.record("expected CoverRefused")
        } catch let e as Runner.CoverRefused {
            #expect(e.message == "Ghostty covers it")
            #expect(e.partial.outcomes["t"]?[.startup] == .notMeasured("preflight refused: Ghostty covers it"))
        }
    }
}

@Suite struct ClickSafetyTests {
    let point = CGPoint(x: 500, y: 400)
    let ours = WindowDescriptor(ownerName: "Alloy", pid: 10, layer: 0, bounds: CGRect(x: 0, y: 0, width: 1200, height: 800))
    let zed = WindowDescriptor(ownerName: "Zed", pid: 99, layer: 0, bounds: CGRect(x: 400, y: 300, width: 300, height: 300))

    @Test func clickAllowedWhenPointIsOverOurWindow() {
        #expect(Harness.pointIsSafe(point, frontPid: 10, tree: [10], windows: [ours]))
    }

    @Test func clickRefusedWhenAnotherAppsWindowIsAboveOurs() {
        #expect(!Harness.pointIsSafe(point, frontPid: 10, tree: [10], windows: [zed, ours]))
    }

    @Test func clickRefusedWhenFrontmostAppIsDifferent() {
        #expect(!Harness.pointIsSafe(point, frontPid: 99, tree: [10], windows: [ours]))
        #expect(!Harness.pointIsSafe(point, frontPid: nil, tree: [10], windows: [ours]))
    }

    @Test func clickRefusedWhenNoWindowContainsThePoint() {
        #expect(!Harness.pointIsSafe(CGPoint(x: 5000, y: 5000), frontPid: 10, tree: [10], windows: [ours]))
    }
}
