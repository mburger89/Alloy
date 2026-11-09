import Foundation

/// The project's files as relative paths: `git ls-files` inside a repository, a directory walk otherwise. Filled by
/// ``refresh()``; ``paths()`` returns the cache, so filtering per keystroke never touches the disk.
public actor FileIndex {
    public static let maxPaths = 100_000
    static let skippedDirectories: Set<String> = [".git", ".build", "node_modules", ".swiftpm", "DerivedData"]

    private let root: URL
    private var cached: [String] = []

    public init(root: URL) { self.root = root }

    /// Rescans the project. The scan runs on a detached task, so the git process and the walk never block this actor
    /// or the main actor.
    public func refresh() async {
        let root = root
        cached = await Task.detached(priority: .userInitiated) { Self.scan(root) }.value
    }

    public func paths() -> [String] { cached }

    nonisolated static func scan(_ root: URL) -> [String] {
        let all = gitFiles(root) ?? walk(root)
        return Array(all.prefix(maxPaths))
    }

    /// nil when `root` is not in a git work tree (or git is missing).
    private static func gitFiles(_ root: URL) -> [String]? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git", "-C", root.path, "ls-files", "--cached", "--others", "--exclude-standard", "-z"]
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        // Drain before waiting: a large listing overflows the pipe buffer.
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        var seen = Set<String>()
        var result: [String] = []
        for part in data.split(separator: 0) {
            let path = String(decoding: part, as: UTF8.self)
            if !path.isEmpty, seen.insert(path).inserted { result.append(path) }
            if result.count >= maxPaths { break }
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
            if result.count >= maxPaths { break }
        }
        return result.sorted()
    }
}
