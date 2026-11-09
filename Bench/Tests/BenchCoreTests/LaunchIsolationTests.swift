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

    @Test func deltaScrollAndMemoryAreUnsupportedWithCaveat() {
        #expect(TargetApp.delta.unsupported[.scrollFrames]?.contains("Delta opens projects, not files") == true)
        #expect(TargetApp.delta.unsupported[.memory]?.contains("Delta opens projects, not files") == true)
        #expect(TargetApp.delta.caveats.contains { $0.contains("no isolation flag") })
        #expect(TargetApp.zed.caveats.isEmpty)
    }

    @Test func stagingCopiesFileAloneIntoFreshDirectory() throws {
        let a = try Staging.stage(Corpus.default.small)
        let b = try Staging.stage(Corpus.default.small)
        defer { a.remove(); b.remove() }
        #expect(a.directory != b.directory)
        #expect(a.file != Corpus.default.small)
        #expect(!a.file.hasPrefix(Corpus.default.small.replacingOccurrences(of: "/small.swift", with: "")))
        #expect(try FileManager.default.contentsOfDirectory(atPath: a.directory!) == ["small.swift"])
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
