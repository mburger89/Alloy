import Foundation

/// A failed `git` call in a test; thrown so the test fails at the call.
public struct GitFailure: Error, CustomStringConvertible {
    public var arguments: [String]
    public var status: Int32
    public var description: String { "git \(arguments.joined(separator: " ")) exited with \(status)" }
}

/// Runs `/usr/bin/git` in `dir` with a fixed identity and no signing, and returns its standard output. Throws
/// `GitFailure` on a non-zero exit. Shared by the tests that build a throwaway repository.
@discardableResult
public func git(_ dir: URL, _ args: String...) throws -> String {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    p.arguments = ["-c", "user.name=t", "-c", "user.email=t@t", "-c", "commit.gpgsign=false"] + args
    p.currentDirectoryURL = dir
    let out = Pipe()
    p.standardOutput = out; p.standardError = FileHandle.nullDevice
    try p.run()
    let data = out.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    guard p.terminationStatus == 0 else { throw GitFailure(arguments: args, status: p.terminationStatus) }
    return String(decoding: data, as: UTF8.self)
}

/// Writes `text` to `rel` under `root`, creating parent directories.
public func writeFile(_ root: URL, _ rel: String, _ text: String) throws {
    let url = root.appendingPathComponent(rel)
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try text.write(to: url, atomically: true, encoding: .utf8)
}

/// A throwaway repository on branch `main` with `files`, optionally committed. The caller removes the directory.
public func makeRepo(files: [String: String], commit: Bool = true) throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("alloy-repo-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try git(root, "init", "-q", "-b", "main")
    for (rel, text) in files { try writeFile(root, rel, text) }
    if commit {
        try git(root, "add", "-A")
        try git(root, "commit", "-q", "-m", "initial")
    }
    return root
}
