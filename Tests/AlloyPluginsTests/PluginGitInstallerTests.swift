import AlloyCore
import AlloyTestSupport
import Foundation
import Testing
@testable import AlloyPlugins

/// A runner that answers every call with one canned result, for the cases a local repository cannot make.
private struct CannedRunner: PluginGitRunner {
    let result: GitResult
    func run(_ args: [String], in dir: URL, timeout: Double, sizeCap: UInt64?, watch: URL?) async -> GitResult { result }
}

@Suite struct PluginGitInstallerTests {
    private let tmp = PluginTestFolder()
    private let id = "dev.example.gitpack"

    private func paths() -> PluginPaths { PluginPaths(appSupport: tmp.root.appendingPathComponent("support")) }

    private func installer(_ runner: any PluginGitRunner = LivePluginGitRunner()) -> PluginGitInstaller {
        PluginGitInstaller(paths: paths(), runner: runner, pathDirs: [])
    }

    private func manifest(_ version: String, extra: String = "") -> String {
        #"{"id":"\#(id)","name":"Pack","version":"\#(version)","contributes":{"themes":[{"path":"themes/a.json"}]}\#(extra)}"#
    }

    private let theme = #"{"name":"Midnight","appearance":"dark","colors":{}}"#

    /// A repository with one release per version, each tagged `v<version>`.
    private func repo(_ versions: [String]) throws -> (dir: URL, url: String) {
        let dir = try makeRepo(files: ["alloy-plugin.json": manifest(versions[0]), "themes/a.json": theme])
        try git(dir, "tag", "v\(versions[0])")
        for version in versions.dropFirst() { try release(dir, version) }
        return (dir, "file://" + dir.path)
    }

    private func release(_ dir: URL, _ version: String, manifestText: String? = nil) throws {
        try writeFile(dir, "alloy-plugin.json", manifestText ?? manifest(version))
        try git(dir, "add", "-A")
        try git(dir, "commit", "-q", "-m", version)
        try git(dir, "tag", "v\(version)")
    }

    private func commit(_ dir: URL, _ rev: String) throws -> String {
        try git(dir, "rev-parse", "\(rev)^{commit}").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func staged() -> [String] { ((try? FileManager.default.contentsOfDirectory(atPath: paths().staging.path)) ?? []) }

    private func setting(_ url: String, tag: String, commit: String, version: String) -> PluginSetting {
        var s = PluginSetting(source: .git(url: url, tag: tag, commit: commit))
        s.version = version
        return s
    }

    @Test func installsTagAndRecordsCommit() async throws {
        let (dir, url) = try repo(["1.0.0", "1.1.0"])
        defer { try? FileManager.default.removeItem(at: dir) }
        let (manifest, commit) = try await installer().install(url: url, tag: "v1.0.0", installed: [:])
        #expect(manifest.id == id)
        #expect(manifest.version == "1.0.0")
        #expect(commit == (try self.commit(dir, "v1.0.0")))
        #expect(commit != (try self.commit(dir, "v1.1.0")))
        let target = paths().plugins.appendingPathComponent(id)
        #expect(FileManager.default.fileExists(atPath: target.appendingPathComponent("themes/a.json").path))
        #expect(staged().isEmpty)
    }

    @Test func hooksAndSubmodulesDoNotRun() async throws {
        let sub = try makeRepo(files: ["inner.txt": "inner"])
        defer { try? FileManager.default.removeItem(at: sub) }
        let (dir, url) = try repo(["1.0.0"])
        defer { try? FileManager.default.removeItem(at: dir) }
        try git(dir, "-c", "protocol.file.allow=always", "submodule", "add", "-q", "file://" + sub.path, "vendor")
        try git(dir, "commit", "-q", "-m", "submodule")
        try git(dir, "tag", "-f", "v1.0.0")
        // The user's own git configuration (`init.templateDir`) copies a post-checkout hook into every new clone, so a
        // plain `git clone` would run it. A control clone proves the hook would run; the installer's clone must not run it.
        let marker = tmp.root.appendingPathComponent("hook-ran")
        let template = tmp.root.appendingPathComponent("template")
        try FileManager.default.createDirectory(at: template.appendingPathComponent("hooks"), withIntermediateDirectories: true)
        let hook = template.appendingPathComponent("hooks/post-checkout")
        try "#!/bin/sh\ntouch '\(marker.path)'\n".write(to: hook, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hook.path)
        let config = tmp.root.appendingPathComponent("gitconfig")
        try "[init]\n\ttemplateDir = \(template.path)\n".write(to: config, atomically: true, encoding: .utf8)
        let runner = LivePluginGitRunner(extraEnvironment: ["GIT_CONFIG_GLOBAL": config.path, "GIT_CONFIG_NOSYSTEM": "1"])
        let control = tmp.root.appendingPathComponent("control")
        let cloned = await runner.run(["clone", "-q", url, control.path], in: tmp.root, timeout: 30, sizeCap: nil, watch: nil)
        #expect(cloned.status == 0)
        #expect(FileManager.default.fileExists(atPath: marker.path), "the template hook runs in a plain clone")
        try FileManager.default.removeItem(at: marker)
        _ = try await installer(runner).install(url: url, tag: "v1.0.0", installed: [:])
        #expect(!FileManager.default.fileExists(atPath: marker.path), "the installer's clone runs no hook")
        let vendor = paths().plugins.appendingPathComponent(id + "/vendor")
        #expect(((try? FileManager.default.contentsOfDirectory(atPath: vendor.path)) ?? []).isEmpty)
    }

    /// Records every git call.
    private final class Recorder: PluginGitRunner, @unchecked Sendable {
        private let lock = NSLock()
        private var _calls: [[String]] = []
        var calls: [[String]] { lock.withLock { _calls } }
        func run(_ args: [String], in dir: URL, timeout: Double, sizeCap: UInt64?, watch: URL?) async -> GitResult {
            lock.withLock { _calls.append(args) }
            return GitResult(status: 128, stderr: Data("fatal: nope\n".utf8))
        }
    }

    @Test func optionLookingURLsAndTagsAreRefusedBeforeAnythingRuns() async throws {
        let recorder = Recorder()
        let gi = installer(recorder)
        for (url, tag) in [("-uwhoami", "v1.0.0"), ("file:///x", "-v"), ("", "v1.0.0")] {
            do {
                _ = try await gi.install(url: url, tag: tag, installed: [:])
                Issue.record("expected a refusal for \(url) \(tag)")
            } catch { if case .git = error {} else { Issue.record("unexpected \(error)") } }
        }
        let installed = setting("-uwhoami", tag: "v1.0.0", commit: "abc", version: "1.0.0")
        do { _ = try await gi.availableUpdate(for: installed, url: "-uwhoami"); Issue.record("expected a refusal") } catch {}
        do {
            _ = try await gi.update(id: id, to: .newer(tag: "v1.1.0", version: "1.1.0", commit: "abc"), url: "--upload-pack=x")
            Issue.record("expected a refusal")
        } catch {}
        #expect(recorder.calls.isEmpty, "nothing was spawned")
    }

    @Test func gitCallsEndOptionsAndTurnOffRiskyFeatures() async throws {
        let recorder = Recorder()
        _ = try? await installer(recorder).install(url: "https://example.com/p.git", tag: "v1.0.0", installed: [:])
        let clone = try #require(recorder.calls.first)
        for flag in ["protocol.ext.allow=never", "core.hooksPath=/dev/null", "submodule.recurse=false"] {
            #expect(clone.contains(flag), "\(flag) in \(clone)")
        }
        let dashes = try #require(clone.firstIndex(of: "--"))
        #expect(clone[dashes + 1] == "https://example.com/p.git")
        #expect(clone.firstIndex(of: "clone")! < dashes)
        let installed = setting("https://example.com/p.git", tag: "v1.0.0", commit: "abc", version: "1.0.0")
        _ = try? await installer(recorder).availableUpdate(for: installed, url: "https://example.com/p.git")
        let ls = try #require(recorder.calls.last)
        #expect(ls.contains("protocol.ext.allow=never") && ls.suffix(2) == ["--", "https://example.com/p.git"])
    }

    @Test func updateUsesTheRecordedURLNotThePluginsOwnGitConfig() async throws {
        let (dir, url) = try repo(["1.0.0", "1.1.0"])
        defer { try? FileManager.default.removeItem(at: dir) }
        let gi = installer()
        _ = try await gi.install(url: url, tag: "v1.0.0", installed: [:])
        // The installed folder's own config now names another origin; it must not be consulted.
        let folder = paths().plugins.appendingPathComponent(id)
        try git(folder, "remote", "set-url", "origin", "file:///definitely/not/here")
        let installed = setting(url, tag: "v1.0.0", commit: try commit(dir, "v1.0.0"), version: "1.0.0")
        let update = try #require(try await gi.availableUpdate(for: installed, url: url))
        let manifest = try await gi.update(id: id, to: update, url: url)
        #expect(manifest.version == "1.1.0")
    }

    @Test func prereleaseVersionsOrderBySemver() throws {
        let order = ["1.0.0-alpha", "1.0.0-alpha.1", "1.0.0-alpha.beta", "1.0.0-beta", "1.0.0-beta.2", "1.0.0-beta.11", "1.0.0-rc.1", "1.0.0", "1.0.1-rc.1", "1.0.1"]
        let versions = try order.map { try #require(PluginSemver($0), "\($0)") }
        for (a, b) in zip(versions, versions.dropFirst()) { #expect(a < b, "\(a.text) < \(b.text)") }
        #expect(PluginSemver("v1.2.3-rc.1+build.5")?.text == "1.2.3-rc.1")
        #expect(PluginSemver("1.0.0-01") == nil && PluginSemver("1.0.0-") == nil && PluginSemver("1.0") == nil)
    }

    @Test func preReleaseInstalledGetsTheRelease() async throws {
        let (dir, url) = try repo(["1.0.0-beta", "1.0.0"])
        defer { try? FileManager.default.removeItem(at: dir) }
        let installed = setting(url, tag: "v1.0.0-beta", commit: try commit(dir, "v1.0.0-beta"), version: "1.0.0-beta")
        let found = try await installer().availableUpdate(for: installed, url: url)
        #expect(found == .newer(tag: "v1.0.0", version: "1.0.0", commit: try commit(dir, "v1.0.0")))
    }

    @Test func preReleaseTagsAreNotOfferedToAReleaseInstall() async throws {
        let (dir, url) = try repo(["1.0.0", "1.1.0-rc.1"])
        defer { try? FileManager.default.removeItem(at: dir) }
        let installed = setting(url, tag: "v1.0.0", commit: try commit(dir, "v1.0.0"), version: "1.0.0")
        #expect(try await installer().availableUpdate(for: installed, url: url) == nil)
    }

    @Test func staleDotPreviousFoldersAreDeleted() throws {
        let plugins = paths().plugins
        try FileManager.default.createDirectory(at: plugins.appendingPathComponent(".a.previous"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: plugins.appendingPathComponent("keep"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: plugins.appendingPathComponent(".staging-ish"), withIntermediateDirectories: true)
        PluginGitInstaller.dropStalePrevious(paths: paths())
        let left = Set(try FileManager.default.contentsOfDirectory(atPath: plugins.path))
        #expect(left == ["keep", ".staging-ish"])
    }

    @Test func credentialURLFailsWithoutPrompt() async throws {
        let stderr = Data("fatal: could not read Username for 'https://example.com': terminal prompts disabled\n".utf8)
        let runner = CannedRunner(result: GitResult(status: 128, stderr: stderr))
        do {
            _ = try await installer(runner).install(url: "https://example.com/p.git", tag: "v1.0.0", installed: [:])
            Issue.record("expected needsCredentials")
        } catch {
            #expect(error == .needsCredentials)
        }
        #expect(staged().isEmpty)
    }

    @Test func overSizeCapFails() async throws {
        let runner = CannedRunner(result: GitResult(status: PluginGitRunnerStatus.sizeCapExceeded))
        do {
            _ = try await installer(runner).install(url: "file:///nowhere", tag: "v1.0.0", installed: [:])
            Issue.record("expected tooLarge")
        } catch {
            #expect(error == .tooLarge)
        }
        #expect(staged().isEmpty)
        #expect(PluginGitInstaller.cloneSizeCap == 209_715_200)
        #expect(PluginGitInstaller.cloneTimeout == 60)
    }

    @Test func timeoutFails() async throws {
        let runner = CannedRunner(result: GitResult(status: 15, timedOut: true))
        do {
            _ = try await installer(runner).install(url: "file:///nowhere", tag: "v1.0.0", installed: [:])
            Issue.record("expected a git error")
        } catch {
            #expect(error == .git("git timed out"))
        }
        #expect(staged().isEmpty)
    }

    @Test func theLiveRunnerKillsAGrowingCloneAtTheCap() async throws {
        // A repository bigger than a tiny cap: the real runner polls the clone's size and kills git.
        let big = String(repeating: "x", count: 600_000)
        let dir = try makeRepo(files: ["alloy-plugin.json": manifest("1.0.0"), "themes/a.json": theme, "big.txt": big])
        defer { try? FileManager.default.removeItem(at: dir) }
        try git(dir, "tag", "v1.0.0")
        let work = tmp.root.appendingPathComponent("work")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        let target = work.appendingPathComponent("clone")
        let result = await LivePluginGitRunner().run(["clone", "file://" + dir.path, target.path], in: work, timeout: 30, sizeCap: 1, watch: target)
        #expect(result.status == PluginGitRunnerStatus.sizeCapExceeded)
    }

    @Test func updatePicksHighestNewerTag() async throws {
        let (dir, url) = try repo(["1.0.0", "1.2.0", "1.10.0"])
        defer { try? FileManager.default.removeItem(at: dir) }
        let installed = setting(url, tag: "v1.0.0", commit: try commit(dir, "v1.0.0"), version: "1.0.0")
        let found = try await installer().availableUpdate(for: installed, url: url)
        #expect(found == .newer(tag: "v1.10.0", version: "1.10.0", commit: try commit(dir, "v1.10.0")))
        let current = setting(url, tag: "v1.10.0", commit: try commit(dir, "v1.10.0"), version: "1.10.0")
        #expect(try await installer().availableUpdate(for: current, url: url) == nil)
    }

    @Test func updateSwapsTheFolderAndKeepsThePreviousOne() async throws {
        let (dir, url) = try repo(["1.0.0", "1.1.0"])
        defer { try? FileManager.default.removeItem(at: dir) }
        let gi = installer()
        _ = try await gi.install(url: url, tag: "v1.0.0", installed: [:])
        let installed = setting(url, tag: "v1.0.0", commit: try commit(dir, "v1.0.0"), version: "1.0.0")
        let update = try #require(try await gi.availableUpdate(for: installed, url: url))
        let manifest = try await gi.update(id: id, to: update, url: url)
        #expect(manifest.version == "1.1.0")
        let target = paths().plugins.appendingPathComponent(id)
        let previous = paths().plugins.appendingPathComponent(".\(id).previous")
        #expect(try String(contentsOf: target.appendingPathComponent("alloy-plugin.json"), encoding: .utf8).contains("1.1.0"))
        #expect(try String(contentsOf: previous.appendingPathComponent("alloy-plugin.json"), encoding: .utf8).contains("1.0.0"))
        try gi.restorePrevious(id: id)
        #expect(try String(contentsOf: target.appendingPathComponent("alloy-plugin.json"), encoding: .utf8).contains("1.0.0"))
        #expect(!FileManager.default.fileExists(atPath: previous.path))
    }

    @Test func downgradeIsRefused() async throws {
        let (dir, url) = try repo(["0.9.0", "1.0.0"])
        defer { try? FileManager.default.removeItem(at: dir) }
        let gi = installer()
        _ = try await gi.install(url: url, tag: "v1.0.0", installed: [:])
        let installed = setting(url, tag: "v1.0.0", commit: try commit(dir, "v1.0.0"), version: "1.0.0")
        #expect(try await gi.availableUpdate(for: installed, url: url) == nil)
        let old = try commit(dir, "v0.9.0")
        do {
            _ = try await gi.update(id: id, to: .newer(tag: "v0.9.0", version: "0.9.0", commit: old), url: url)
            Issue.record("expected downgrade")
        } catch {
            #expect(error == .downgrade)
        }
        let target = paths().plugins.appendingPathComponent(id)
        #expect(try String(contentsOf: target.appendingPathComponent("alloy-plugin.json"), encoding: .utf8).contains("1.0.0"))
    }

    @Test func movedTagIsShownNotInstalled() async throws {
        let (dir, url) = try repo(["1.0.0"])
        defer { try? FileManager.default.removeItem(at: dir) }
        let gi = installer()
        let (_, commit) = try await gi.install(url: url, tag: "v1.0.0", installed: [:])
        try writeFile(dir, "extra.txt", "changed")
        try git(dir, "add", "-A")
        try git(dir, "commit", "-q", "-m", "rewrite")
        try git(dir, "tag", "-f", "v1.0.0")
        let installed = setting(url, tag: "v1.0.0", commit: commit, version: "1.0.0")
        let found = try await gi.availableUpdate(for: installed, url: url)
        #expect(found == .tagMoved(tag: "v1.0.0"))
        do {
            _ = try await gi.update(id: id, to: .tagMoved(tag: "v1.0.0"), url: url)
            Issue.record("expected a refusal")
        } catch {
            if case .git = error {} else { Issue.record("expected a git error, got \(error)") }
        }
        let target = paths().plugins.appendingPathComponent(id)
        #expect(!FileManager.default.fileExists(atPath: target.appendingPathComponent("extra.txt").path))
    }

    @Test func badManifestInTagLeavesNothing() async throws {
        let dir = try makeRepo(files: ["alloy-plugin.json": manifest("1.2"), "themes/a.json": theme])
        defer { try? FileManager.default.removeItem(at: dir) }
        try git(dir, "tag", "v1.0.0")
        do {
            _ = try await installer().install(url: "file://" + dir.path, tag: "v1.0.0", installed: [:])
            Issue.record("expected badManifest")
        } catch {
            if case .badManifest = error {} else { Issue.record("expected badManifest, got \(error)") }
        }
        #expect(!FileManager.default.fileExists(atPath: paths().plugins.appendingPathComponent(id).path))
        #expect(staged().isEmpty)
    }
}
