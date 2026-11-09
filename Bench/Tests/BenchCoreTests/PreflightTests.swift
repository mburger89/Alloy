import AppKit
import Testing
import Foundation
@testable import BenchCore
@testable import BenchDrivers
@testable import BenchScenarios

/// Non-live: nothing here launches or touches a GUI app.
@Suite struct PreflightTests {
    private func app(path: String = "/nonexistent/bench-app", bundleID: String? = nil, unsupported: [Metric: String] = [:]) -> TargetApp {
        TargetApp(id: "t", displayName: "T", bundlePath: nil, executablePath: path, launchArguments: { _ in [] },
                  unsupported: unsupported, bundleID: bundleID)
    }

    @Test func rootMostPicksTheMainProcessNotTheCrashHandler() {
        let parent: [pid_t: pid_t] = [200: 100, 100: 1, 300: 200]
        #expect(Launcher.rootMost([300, 200, 100], parentOf: { parent[$0] }) == 100)
        #expect(Launcher.rootMost([200, 100], parentOf: { parent[$0] }) == 100)
        #expect(Launcher.rootMost([], parentOf: { parent[$0] }) == nil)
    }

    @Test func detectsRunningInstanceByBundleIdentifier() {
        // Finder is always running; only NSRunningApplication can find it from this fake path.
        let finder = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder").first?.processIdentifier
        #expect(finder != nil)
        #expect(Launcher.runningInstance(of: app(bundleID: "com.apple.finder")) == finder)
        #expect(Launcher.runningInstance(of: app(bundleID: "dev.example.not-running")) == nil)
    }

    @Test func targetBundleIdentifiersAreTheRealOnes() {
        #expect(TargetApp.zed.bundleID == "dev.zed.Zed")
        #expect(TargetApp.delta.bundleID == "com.zed-industries.delta")
    }

    @Test func refusalMessageNamesMainPid() {
        // /bin/sh is running (this process tree includes shells); Preflight reports a pid and the app name.
        let msg = Preflight.runningMessage(for: app(bundleID: "com.apple.finder"))
        #expect(msg?.contains("T is already running (pid ") == true)
    }

    @Test func runnerRerunsPreflightPerAppAndRecordsRefusalWithoutLaunching() async {
        let seen = Box<[String]>([])
        let apps = [app(), TargetApp(id: "u", displayName: "U", bundlePath: nil, executablePath: "/nonexistent/u",
                                     launchArguments: { _ in [] })]
        let r = try? await Runner.run(apps: apps, metrics: [.startup], corpus: .default, runsOverride: 1,
                                      preflight: { a in seen.update { $0.append(a.id) }; return "\(a.displayName) is already running (pid 7)" })
        #expect(seen.value == ["t", "u"])
        for id in ["t", "u"] {
            guard case .notMeasured(let why)? = r?.outcomes[id]?[.startup] else { Issue.record("expected refusal for \(id)"); continue }
            #expect(why.contains("already running"))
        }
    }

    @Test func leftoverDetectionFindsOnlyProcessesStartedAfterHarnessStart() async throws {
        let dir = NSTemporaryDirectory() + "bench-left-\(getpid())"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let exe = dir + "/benchleft"
        try FileManager.default.copyItem(atPath: "/bin/sleep", toPath: exe)
        let sign = Process(); sign.executableURL = URL(fileURLWithPath: "/usr/bin/codesign"); sign.arguments = ["-s", "-", "-f", exe]
        sign.standardError = FileHandle.nullDevice
        try sign.run(); sign.waitUntilExit()   // a copied system binary needs a fresh ad-hoc signature to run
        let target = app(path: exe)
        let before = Launcher.nowMicroseconds()
        #expect(Leftovers.find(apps: [target], since: before).isEmpty)
        let p = Process(); p.executableURL = URL(fileURLWithPath: exe); p.arguments = ["30"]
        try p.run()
        defer { p.terminate(); p.waitUntilExit() }
        try await Task.sleep(for: .milliseconds(100))
        let found = Leftovers.find(apps: [target], since: before)
        #expect(found.map(\.pid) == [p.processIdentifier])
        #expect(Leftovers.find(apps: [target], since: Launcher.nowMicroseconds()).isEmpty)   // older than harness start: not ours
        #expect(Leftovers.warnings(apps: [target], since: before).first?.contains("leftover process") == true)
        #expect(kill(p.processIdentifier, 0) == 0, "report only: the process must still be alive")
    }
}
