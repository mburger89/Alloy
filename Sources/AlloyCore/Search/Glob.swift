import Foundation

/// Include/exclude path filter for project search. Patterns are comma separated; paths are
/// project-relative and use `/`.
///
/// - `**` matches zero or more path segments; other segments use `fnmatch(3)` (so `*` matches
///   dotfiles).
/// - A pattern without `/` is matched against any path suffix (`*.swift` behaves as `**/*.swift`).
/// - A bare name (no `/`, `*`, `?`, `[`) means a directory or file of that name anywhere
///   (`build` behaves as `**/build/**` plus `**/build`).
/// - A trailing `/` means everything below that directory.
public struct GlobFilter: Sendable {
    private let include: [[String]]
    private let exclude: [[String]]

    public init(include: String, exclude: String, extraExclude: [String] = []) {
        self.include = Self.compile(include)
        self.exclude = Self.compile(exclude) + extraExclude.flatMap { Self.compile($0) }
    }

    public func allows(_ path: String) -> Bool {
        let segments = path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        if exclude.contains(where: { Self.match($0, segments) }) { return false }
        if include.isEmpty { return true }
        return include.contains { Self.match($0, segments) }
    }

    private static func compile(_ list: String) -> [[String]] {
        var out: [[String]] = []
        for raw in list.split(separator: ",") {
            var pattern = raw.trimmingCharacters(in: .whitespaces)
            if pattern.isEmpty { continue }
            while pattern.hasPrefix("./") { pattern.removeFirst(2) }
            if pattern.hasPrefix("/") { pattern.removeFirst() }
            if pattern.isEmpty { continue }
            let directory = pattern.hasSuffix("/")
            if directory { pattern.removeLast() }
            let isBare = !pattern.contains(where: { "/*?[".contains($0) })
            let segments = pattern.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
            if segments.isEmpty { continue }
            if directory {
                out.append(anchored(segments) + ["**"])
            } else if isBare {
                out.append(["**"] + segments + ["**"])
                out.append(["**"] + segments)
            } else {
                out.append(anchored(segments))
            }
        }
        return out
    }

    /// A pattern with no `/` matches anywhere in the tree.
    private static func anchored(_ segments: [String]) -> [String] {
        segments.count == 1 && segments[0] != "**" ? ["**"] + segments : segments
    }

    private static func match(_ pattern: [String], _ path: [String]) -> Bool {
        matchFrom(pattern, 0, path, 0)
    }

    private static func matchFrom(_ pattern: [String], _ pi: Int, _ path: [String], _ si: Int) -> Bool {
        var pi = pi
        var si = si
        while pi < pattern.count {
            if pattern[pi] == "**" {
                while pi < pattern.count, pattern[pi] == "**" { pi += 1 }
                if pi == pattern.count { return true }
                var k = si
                while k <= path.count {
                    if matchFrom(pattern, pi, path, k) { return true }
                    k += 1
                }
                return false
            }
            guard si < path.count, fnmatch(pattern[pi], path[si], 0) == 0 else { return false }
            pi += 1
            si += 1
        }
        return si == path.count
    }
}
