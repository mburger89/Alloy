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
