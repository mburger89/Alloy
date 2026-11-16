import Foundation

/// The project's files as relative paths: `git ls-files` inside a repository, a directory walk otherwise. Filled by
/// ``refresh()``; ``paths()`` returns the cache, so filtering per keystroke never touches the disk.
public actor FileIndex {
    public static let maxPaths = 100_000
    static let skippedDirectories: Set<String> = [".git", ".build", "node_modules", ".swiftpm", "DerivedData"]

    private let root: URL
    private var cached: [String] = []
    private var truncated = false

    public init(root: URL) { self.root = root }

    /// Rescans the project. The scan runs on a detached task, so the git process and the walk never block this actor
    /// or the main actor.
    public func refresh() async {
        let root = root
        let result = await Task.detached(priority: .userInitiated) { Self.scanAll(root) }.value
        cached = result.paths
        truncated = result.truncated
    }

    public func paths() -> [String] { cached }

    /// True when the project has more than ``maxPaths`` files and the listing stops at the limit.
    public var isTruncated: Bool { truncated }

    nonisolated static func scan(_ root: URL) -> [String] { scanAll(root).paths }

    nonisolated static func scanAll(_ root: URL) -> (paths: [String], truncated: Bool) {
        let all = gitFiles(root) ?? walk(root)
        return (Array(all.prefix(maxPaths)), all.count > maxPaths)
    }

    private static func git(_ root: URL, _ args: [String]) -> Data? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git", "-C", root.path] + args
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        // Drain before waiting: a large listing overflows the pipe buffer.
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return process.terminationStatus == 0 ? data : nil
    }

    /// nil when `root` is not in a git work tree (or git is missing).
    private static func gitFiles(_ root: URL) -> [String]? {
        guard let data = git(root, ["ls-files", "--cached", "--others", "--exclude-standard", "-z"]) else { return nil }
        // A tracked file removed from disk is still in the index; it is not a file the tree can open. One lstat per path
        // (this runs off the main actor) replaces a second `git ls-files --deleted` process.
        let base = root.path.hasSuffix("/") ? root.path : root.path + "/"
        var info = stat()
        var seen = Set<String>()
        var result: [String] = []
        for part in data.split(separator: 0) {
            let path = String(decoding: part, as: UTF8.self)
            if !path.isEmpty, lstat(base + path, &info) == 0, seen.insert(path).inserted { result.append(path) }
            // One past the limit tells the caller the listing was cut.
            if result.count > maxPaths { break }
        }
        return result
    }

    private static func walk(_ root: URL) -> [String] {
        let base = root.resolvingSymlinksInPath().standardizedFileURL.path
        let prefix = base.hasSuffix("/") ? base : base + "/"
        guard let walker = FileManager.default.enumerator(
            at: URL(fileURLWithPath: base), includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey], options: []
        ) else { return [] }
        var result: [String] = []
        for case let url as URL in walker {
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey])
            if values?.isDirectory == true {
                if skippedDirectories.contains(url.lastPathComponent) { walker.skipDescendants() }
                continue
            }
            guard values?.isRegularFile == true else { continue }
            let path = url.standardizedFileURL.path
            if path.hasPrefix(prefix) { result.append(String(path.dropFirst(prefix.count))) }
            if result.count > maxPaths { break }
        }
        return result.sorted()
    }
}
