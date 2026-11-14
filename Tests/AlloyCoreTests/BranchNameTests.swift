@testable import AlloyCore
import Foundation
import Testing

@MainActor @Suite struct BranchNameTests {
    private func project(head: String?) throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("alloy-branch-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        if let head {
            try FileManager.default.createDirectory(at: root.appendingPathComponent(".git"), withIntermediateDirectories: true)
            try head.write(to: root.appendingPathComponent(".git/HEAD"), atomically: true, encoding: .utf8)
        }
        return root
    }

    private func workspace(_ root: URL) -> Workspace {
        Workspace(projectRoot: root, appSupport: root.appendingPathComponent("support"), settings: AlloySettings())
    }

    @Test func readsABranchRef() throws {
        let root = try project(head: "ref: refs/heads/feat/x\n")
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(workspace(root).branchName == "feat/x")
    }

    @Test func detachedHeadIsAShortHash() throws {
        let root = try project(head: "0123456789abcdef0123456789abcdef01234567\n")
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(workspace(root).branchName == "0123456")
    }

    @Test func noGitIsNil() throws {
        let root = try project(head: nil)
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(workspace(root).branchName == nil)
    }

    @Test func worktreePointerFileIsFollowed() throws {
        let root = try project(head: nil)
        defer { try? FileManager.default.removeItem(at: root) }
        let real = root.appendingPathComponent("elsewhere")
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        try "ref: refs/heads/wt\n".write(to: real.appendingPathComponent("HEAD"), atomically: true, encoding: .utf8)
        try "gitdir: \(real.path)\n".write(to: root.appendingPathComponent(".git"), atomically: true, encoding: .utf8)
        #expect(workspace(root).branchName == "wt")
    }

    @Test func relativeGitdirPointerIsResolvedFromTheProject() throws {
        let root = try project(head: nil)
        defer { try? FileManager.default.removeItem(at: root) }
        let real = root.appendingPathComponent("meta/wt")
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        try "ref: refs/heads/rel\n".write(to: real.appendingPathComponent("HEAD"), atomically: true, encoding: .utf8)
        try "gitdir: meta/wt\n".write(to: root.appendingPathComponent(".git"), atomically: true, encoding: .utf8)
        #expect(workspace(root).branchName == "rel")
    }

    @Test func branchNameFollowsAHeadChange() throws {
        let root = try project(head: "ref: refs/heads/one\n")
        defer { try? FileManager.default.removeItem(at: root) }
        let ws = workspace(root)
        #expect(ws.branchName == "one")
        try "ref: refs/heads/two\n".write(to: root.appendingPathComponent(".git/HEAD"), atomically: true, encoding: .utf8)
        ws.baselineEventSeen()
        #expect(ws.branchName == "two")
    }
}
