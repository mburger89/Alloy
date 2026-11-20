import Foundation

public enum ACPPathError: Error, Equatable, LocalizedError, Sendable {
    case empty
    case outsideProject

    public var errorDescription: String? {
        switch self {
        case .empty: "The path is empty."
        case .outsideProject: "The path is outside the project; Alloy only gives agents access to files inside the project."
        }
    }
}

/// Decides which files an agent's `fs/*` requests may touch: inside the project root once symlinks are resolved,
/// and which of those need the user's approval before they are written. Pure path logic plus symlink lookups.
public struct ACPPathPolicy: Sendable {
    public let root: URL
    /// The root with symlinks resolved; every accepted path is under it.
    public let realRoot: String

    public init(root: URL) {
        self.root = root.standardizedFileURL
        self.realRoot = Self.realPath(root.path) ?? root.standardizedFileURL.path
    }

    /// Directories whose contents change what runs on the machine or how tools behave; any path with one of these as
    /// a component is protected.
    /// Names without the leading dot (a dot directory is matched by `isProtectedDirectory`).
    static let protectedDirectoryNames: Set<String> = ["git", "claude", "codex", "goose", "gemini", "vscode", "cursor", "husky", "githooks"]

    static func isProtectedDirectory(_ component: String) -> Bool {
        component.hasPrefix(".") && protectedDirectoryNames.contains(String(component.dropFirst()))
    }
    /// Protected file names, compared lowercased.
    static let protectedFiles: Set<String> = ["opencode.json", "opencode.jsonc", ".mcp.json", "mcp.json", ".gitmodules"]

    /// `path` (absolute, or relative to the project root) as the real location to touch. Symlinks are resolved on
    /// the deepest part that exists, so a link that leaves the project is refused, and so is `..` out of it.
    public func resolve(_ path: String) -> Result<URL, ACPPathError> {
        guard !path.isEmpty, !path.contains("\0") else { return .failure(.empty) }
        let lexical = Self.lexical(path.hasPrefix("/") ? path : root.path + "/" + path)
        guard let real = Self.resolveExisting(lexical) else { return .failure(.outsideProject) }
        guard Self.isInside(real, root: realRoot) || Self.isInside(real, root: root.path) else { return .failure(.outsideProject) }
        return .success(URL(fileURLWithPath: real))
    }

    /// The path with `.` and `..` resolved without looking at the disk, as a URL (for the protected check of the
    /// name the agent used, before symlinks).
    public func lexicalURL(_ path: String) -> URL {
        URL(fileURLWithPath: Self.lexical(path.hasPrefix("/") ? path : root.path + "/" + path))
    }

    /// Whether writing `url` needs the user's approval. Judges the components below the project root, so a project
    /// that itself lives under a `.git` or `.claude` directory is not protected wholesale.
    public func isProtected(_ url: URL) -> Bool {
        guard let rel = relative(url) else { return true }
        let parts = rel.split(separator: "/").map { $0.lowercased() }
        guard let last = parts.last else { return false }
        if parts.dropLast().contains(where: Self.isProtectedDirectory) { return true }
        if Self.isProtectedDirectory(last) { return true }
        if last == ".env" || last.hasPrefix(".env.") || Self.protectedFiles.contains(last) { return true }
        return false
    }

    /// The project-relative form of `url`, nil outside the project.
    public func relative(_ url: URL) -> String? {
        let p = Self.lexical(url.path)
        for base in [realRoot, root.path] where Self.isInside(p, root: base) {
            return base == "/" ? String(p.dropFirst()) : String(p.dropFirst(base.count + 1))
        }
        return nil
    }

    // MARK: helpers

    private static func isInside(_ path: String, root: String) -> Bool {
        let prefix = root == "/" ? "/" : root + "/"
        return path.hasPrefix(prefix) && path.count > prefix.count
    }

    static func lexical(_ path: String) -> String {
        var parts: [Substring] = []
        for p in path.split(separator: "/", omittingEmptySubsequences: true) {
            if p == "." { continue }
            if p == ".." { _ = parts.popLast(); continue }
            parts.append(p)
        }
        return "/" + parts.joined(separator: "/")
    }

    /// realpath of the deepest existing ancestor, with the rest appended. Nil only when the lookup fails oddly.
    private static func resolveExisting(_ lexical: String) -> String? {
        var existing = lexical
        var tail: [String] = []
        while !FileManager.default.fileExists(atPath: existing) && lstatExists(existing) == false {
            guard existing != "/" else { break }
            tail.insert((existing as NSString).lastPathComponent, at: 0)
            existing = (existing as NSString).deletingLastPathComponent
            if existing.isEmpty { existing = "/" }
        }
        guard let real = realPath(existing) else { return nil }
        return tail.isEmpty ? real : (real == "/" ? "" : real) + "/" + tail.joined(separator: "/")
    }

    /// True when the path exists as a link, even a dangling one (`fileExists` follows links).
    private static func lstatExists(_ path: String) -> Bool {
        var st = stat()
        return lstat(path, &st) == 0
    }

    static func realPath(_ path: String) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        guard realpath(path, &buffer) != nil else { return nil }
        return String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }
}
