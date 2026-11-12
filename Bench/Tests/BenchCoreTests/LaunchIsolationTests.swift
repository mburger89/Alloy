import Testing
import Foundation
@testable import BenchCore
@testable import BenchDrivers
@testable import BenchScenarios

/// Non-live tests: no GUI app is ever launched.
@Suite struct LaunchIsolationTests {
    @Test func zedDoesNotPassNewWindowFlag() {
        #expect(!TargetApp.zed.launchArguments("/tmp/a.swift").contains("-n"))
        #expect(TargetApp.zed.launchArguments("/tmp/a.swift") == ["/tmp/a.swift"])
        #expect(TargetApp.zed.userDataDirFlag == "--user-data-dir")
    }

    @Test func launcherAddsUserDataDirForZedOnly() {
        let args = Launcher.arguments(for: .zed, file: "/tmp/a.swift", userDataDir: "/tmp/ud")
        #expect(args == ["--user-data-dir", "/tmp/ud", "/tmp/a.swift"])
        #expect(Launcher.arguments(for: .delta, file: "/tmp/d/a.swift", userDataDir: nil) == ["/tmp/d"])
        #expect(Launcher.arguments(for: .alloy(buildDir: "/x"), file: "/tmp/d/a.swift", userDataDir: nil) == ["/tmp/d", "/tmp/d/a.swift"])
    }

    /// Alloy's typing run autosaves and records ledgers; the launch points its data directory at a per-run temp dir.
    @Test func launcherIsolatesAlloyDataThroughTheEnvironment() {
        let app = TargetApp.alloy(buildDir: "/x")
        #expect(app.dataDirEnvironmentKey == "ALLOY_DATA_DIR")
        let env = Launcher.environment(for: app, userDataDir: "/tmp/ud", base: ["PATH": "/usr/bin", "ALLOY_DATA_DIR": "/real"])
        #expect(env?["ALLOY_DATA_DIR"] == "/tmp/ud")
        #expect(env?["PATH"] == "/usr/bin")
        // Apps without the key inherit the environment unchanged.
        #expect(Launcher.environment(for: .zed, userDataDir: "/tmp/ud", base: ["PATH": "/usr/bin"]) == nil)
        #expect(TargetApp.zed.dataDirEnvironmentKey == nil)
    }

    @Test func extraEnvOnlyForAlloy() {
        let extra = ["ALLOY_FRAME_TIMING": "1"]
        let env = Launcher.environment(for: .alloy(buildDir: "/x"), userDataDir: "/tmp/d", extra: extra, base: [:])
        #expect(env?["ALLOY_FRAME_TIMING"] == "1")
        #expect(env?["ALLOY_DATA_DIR"] == "/tmp/d")
        #expect(Launcher.environment(for: .zed, userDataDir: "/tmp/d", extra: extra, base: [:])?["ALLOY_FRAME_TIMING"] == nil)
        #expect(Launcher.environment(for: .delta, userDataDir: nil, extra: extra, base: [:]) == nil)
        // Without extra nothing is added.
        #expect(Launcher.environment(for: .alloy(buildDir: "/x"), userDataDir: "/tmp/d", base: [:])?["ALLOY_FRAME_TIMING"] == nil)
    }

    @Test func terminateCollectsFileBeforeRemovingDirectory() async throws {
        let dir = NSTemporaryDirectory() + "bench-collect-\(getpid())"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try Data("hello".utf8).write(to: URL(fileURLWithPath: dir + "/frame-timing.json"))
        let gone = LaunchedApp(pid: 0, launchedAt: 0, startTime: 0, userDataDir: dir)
        let data = await Launcher.terminate(gone, collecting: "frame-timing.json")
        #expect(data == Data("hello".utf8))
        #expect(!FileManager.default.fileExists(atPath: dir))
        // Absent file: no data, never a failure.
        let empty = NSTemporaryDirectory() + "bench-collect-empty-\(getpid())"
        try FileManager.default.createDirectory(atPath: empty, withIntermediateDirectories: true)
        let none = await Launcher.terminate(LaunchedApp(pid: 0, launchedAt: 0, startTime: 0, userDataDir: empty), collecting: "frame-timing.json")
        #expect(none == nil)
        #expect(!FileManager.default.fileExists(atPath: empty))
    }

    @Test func deltaScrollAndMemoryAreUnsupportedWithCaveat() {
        #expect(TargetApp.delta.unsupported[.scrollFrames]?.contains("Delta opens projects, not files") == true)
        #expect(TargetApp.delta.unsupported[.memory]?.contains("Delta opens projects, not files") == true)
        #expect(TargetApp.delta.caveats.contains { $0.contains("no isolation flag") })
        #expect(TargetApp.zed.caveats.contains { $0.contains("pre-trusts the project") })
        #expect(TargetApp.zed.caveats.allSatisfy { !$0.contains("/") })
        #expect(!TargetApp.alloy(buildDir: "/x").caveats.contains { $0.contains("pre-trusts") })
    }

    @Test func zedSeedsTrustedSettings() throws {
        let json = try #require(TargetApp.zed.seededFiles["config/settings.json"])
        let obj = try #require(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        #expect((obj["session"] as? [String: Any])?["trust_all_worktrees"] as? Bool == true)
        #expect(obj["enable_language_server"] as? Bool == false)
        #expect(TargetApp.delta.seededFiles.isEmpty)
        #expect(TargetApp.alloy(buildDir: "/x").seededFiles.isEmpty)
    }

    @Test func seedWritesNestedFilesUnderDirectory() throws {
        let dir = NSTemporaryDirectory() + "bench-seed-\(getpid())-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: dir) }
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try Launcher.seed(["config/settings.json": "{}\n", "a/b/c.txt": "x"], into: dir)
        #expect(try String(contentsOfFile: dir + "/config/settings.json", encoding: .utf8) == "{}\n")
        #expect(try String(contentsOfFile: dir + "/a/b/c.txt", encoding: .utf8) == "x")
        try Launcher.seed([:], into: dir)
    }

    @Test func zedNoteSurvivesScrubbingAndReachesOnlyZed() {
        let note = TargetApp.zed.caveats[0]
        #expect(Scrubber(home: "/home/tester", userName: "tester").scrub(note) == note)
    }

    @Test func stagingCopiesFileAloneIntoFreshDirectory() throws {
        let a = try Staging.stage(Corpus.default.small)
        let b = try Staging.stage(Corpus.default.small)
        defer { a.remove(); b.remove() }
        #expect(a.directory != b.directory)
        #expect(a.file != Corpus.default.small)
        #expect(!a.file.hasPrefix(Corpus.default.small.replacingOccurrences(of: "/small.rs", with: "")))
        #expect(try FileManager.default.contentsOfDirectory(atPath: a.directory!) == ["small.rs"])
        #expect(try Data(contentsOf: URL(fileURLWithPath: a.file)) == Data(contentsOf: URL(fileURLWithPath: Corpus.default.small)))
        // Editing the copy leaves the committed corpus untouched.
        try "x".write(toFile: a.file, atomically: true, encoding: .utf8)
        #expect(try Data(contentsOf: URL(fileURLWithPath: Corpus.default.small)).count > 1)
        a.remove()
        #expect(!FileManager.default.fileExists(atPath: a.directory!))
    }

    @Test func stagingPassesThroughNonFilesAndNeverTouchesCorpus() throws {
        let s = try Staging.stage("static")
        #expect(s.file == "static" && s.directory == nil)
        s.remove()
    }

    @Test func startTimeRetriesThenGivesUp() {
        let calls = Box<Int>(0)
        let t0 = ContinuousClock.now
        let r = Launcher.acquireStartTime(of: 1, lookup: { _ in calls.update { $0 += 1 }; return nil })
        #expect(r == nil)
        #expect(ContinuousClock.now - t0 >= .milliseconds(40))
        #expect(calls.value > 2)
        let n = Box<Int>(0)
        let ok = Launcher.acquireStartTime(of: 1, lookup: { _ in n.update { $0 += 1 }; return n.value >= 3 ? 42 : nil })
        #expect(ok == 42)
    }

    @Test func userDataDirIsCreatedAndRemovedWithTheLaunch() async throws {
        let script = NSTemporaryDirectory() + "bench-ud-\(getpid()).sh"
        try "#!/bin/sh\nexec sleep 30\n".write(toFile: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script)
        defer { try? FileManager.default.removeItem(atPath: script) }
        let app = TargetApp(id: "ud", displayName: "UD", bundlePath: nil, executablePath: script,
                            launchArguments: { _ in [] }, userDataDirFlag: "--user-data-dir")
        let l = try Launcher.launch(app, file: nil)
        let dir = try #require(l.userDataDir)
        #expect(FileManager.default.fileExists(atPath: dir))
        await Launcher.terminate(l)
        #expect(!FileManager.default.fileExists(atPath: dir))
    }
}
