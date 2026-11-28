@testable import AlloyCore
import AlloyTestSupport
import Foundation
import Testing

@Suite struct FileIndexTests {
    private func tempDir() throws -> URL {
        let url = TempFiles.url("alloy-fi")
            .resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func write(_ root: URL, _ path: String, _ text: String = "x") throws {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    @Test func gitIndexHonoursIgnore() async throws {
        let root = try tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        try git(root, "init", "-q")
        try write(root, ".gitignore", "build/\n")
        try write(root, "build/out.o")
        try write(root, "src/a.swift")
        try write(root, "tracked file.txt")
        let index = FileIndex(root: root)
        await index.refresh()
        let paths = await index.paths()
        #expect(paths.contains("src/a.swift"))
        #expect(paths.contains("tracked file.txt"))
        #expect(paths.contains(".gitignore"))
        #expect(!paths.contains { $0.hasPrefix("build/") })
    }

    @Test func fileIndexUsesWalkWhenGitShimHasNoTools() throws {
        let root = try tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        try git(root, "init", "-q")
        try write(root, "src/a.swift")
        let marker = root.appendingPathComponent("marker-ran")
        let script = root.appendingPathComponent("fake-git.sh")
        try "#!/bin/sh\ntouch '\(marker.path)'\n".write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        let result = FileIndex.scanAll(root, git: .shimWithoutTools).paths
        #expect(result.contains("src/a.swift"))
        #expect(result == FileIndex.scanAll(root, git: .notFound).paths)
        #expect(!FileManager.default.fileExists(atPath: marker.path))
    }

    @Test func fileIndexRunsTheResolvedGitPath() throws {
        let root = try tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        try write(root, "real.txt")
        let script = root.appendingPathComponent("fake-git.sh")
        try "#!/bin/sh\nprintf 'real.txt\\0'\n".write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        let files = FileIndex.gitFiles(root, git: .usable(path: script.path, version: [2, 40]))
        #expect(files == ["real.txt"])
    }

    @Test func nonGitWalkSkipsBuild() async throws {
        let root = try tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        try write(root, "src/a.swift")
        for dir in [".git", ".build", "node_modules", ".swiftpm", "DerivedData"] { try write(root, "\(dir)/x/y.txt") }
        try write(root, "src/node_modules/z.js")
        let index = FileIndex(root: root)
        await index.refresh()
        #expect(await index.paths() == ["src/a.swift"])
    }

    @Test func emptyBeforeRefresh() async throws {
        let index = FileIndex(root: try tempDir())
        #expect(await index.paths().isEmpty)
    }

    @Test func deletedTrackedFileIsNotListed() async throws {
        let root = try tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        try git(root, "init", "-q")
        try write(root, "keep.txt"); try write(root, "gone.txt")
        try git(root, "add", ".")
        try git(root, "-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "-m", "x")
        try FileManager.default.removeItem(at: root.appendingPathComponent("gone.txt"))
        let index = FileIndex(root: root)
        await index.refresh()
        #expect(await index.paths() == ["keep.txt"])
    }

    @Test func untrackedUnignoredFileIsListed() async throws {
        let root = try tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        try git(root, "init", "-q")
        try write(root, "new.txt")
        let index = FileIndex(root: root)
        await index.refresh()
        #expect(await index.paths() == ["new.txt"])
    }

    @Test func ignoredFileIsHidden() async throws {
        let root = try tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        try git(root, "init", "-q")
        try write(root, ".gitignore", "*.log\n"); try write(root, "a.log"); try write(root, "a.txt")
        let index = FileIndex(root: root)
        await index.refresh()
        #expect(!(await index.paths()).contains("a.log"))
        #expect(await index.paths().contains("a.txt"))
    }

    @Test func gitDirectoryNeverListed() async throws {
        let root = try tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        try git(root, "init", "-q")
        try write(root, "a.txt")
        let index = FileIndex(root: root)
        await index.refresh()
        #expect(!(await index.paths()).contains { $0.hasPrefix(".git/") })
    }

    @Test func walkSkipsBuildAndNodeModules() async throws {
        let root = try tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        try write(root, "a.txt"); try write(root, "node_modules/x.js"); try write(root, ".build/y")
        let index = FileIndex(root: root)
        await index.refresh()
        #expect(await index.paths() == ["a.txt"])
        #expect(await index.isTruncated == false)
    }
}
