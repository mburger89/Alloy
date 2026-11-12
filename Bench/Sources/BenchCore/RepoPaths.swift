import Foundation

/// Locates the repository root so default paths do not depend on the current directory.
public enum RepoPaths {
    public struct NotFound: Error, CustomStringConvertible {
        public var description: String {
            "cannot find the repository root (a directory containing Bench/Package.swift) above the current directory; run from inside the repository or pass explicit paths"
        }
    }

    /// The nearest directory at or above `start` that contains `Bench/Package.swift`, or nil.
    public static func root(from start: URL) -> URL? {
        var dir = start.standardizedFileURL
        let fm = FileManager.default
        while true {
            if fm.fileExists(atPath: dir.appendingPathComponent("Bench/Package.swift").path) { return dir }
            if dir.path == "/" || dir.path.isEmpty { return nil }
            dir = dir.deletingLastPathComponent().standardizedFileURL
        }
    }

    /// An explicit option stays relative to the current directory as given; otherwise `<root>/<fallback>`.
    public static func resolve(_ explicit: String?, fallback: String, cwd: URL) throws -> URL {
        if let explicit {
            if explicit.hasPrefix("/") { return URL(fileURLWithPath: explicit).standardizedFileURL }
            return URL(fileURLWithPath: cwd.path, isDirectory: true).appendingPathComponent(explicit).standardizedFileURL
        }
        guard let r = root(from: cwd) else { throw NotFound() }
        return r.appendingPathComponent(fallback)
    }
}
