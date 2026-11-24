import Foundation

/// Why `project/write` from a plugin is refused. The raw value is the `reason` in the error's data.
public enum PluginWriteRefusal: String, Sendable, Error {
    /// The file is open with unsaved edits.
    case dirty
    /// A Claude Code session has a pending change to the file.
    case claudeEditing
    /// The path is absolute, climbs out with `..`, or a symlink resolves outside the project.
    case outsideProject
    /// The path is, or resolves into, a `.claude` or `.git` folder (git hooks would make a write into code execution).
    case protectedPath
}

extension Workspace {
    /// The project-relative form of a plugin-supplied path, or nil when it is absolute, empty or climbs out with `..`.
    public static func pluginRelativePath(_ path: String) -> String? {
        guard !path.isEmpty, !path.hasPrefix("/"), !path.hasPrefix("~") else { return nil }
        var parts: [Substring] = []
        for part in path.split(separator: "/", omittingEmptySubsequences: true) {
            if part == "." { continue }
            if part == ".." { return nil }
            parts.append(part)
        }
        return parts.isEmpty ? nil : parts.joined(separator: "/")
    }

    /// Resolves a plugin's path to the file it names and checks it stays inside the project (symlinks resolved). Returns the
    /// project-relative path and URL, or the refusal. `.claude` and `.git` anywhere in the path, or in what it resolves to,
    /// are `protectedPath` (the caller decides whether reads care).
    public func pluginResolve(_ path: String) -> Result<(relative: String, url: URL, protected: Bool), PluginWriteRefusal> {
        guard let relative = Self.pluginRelativePath(path) else { return .failure(.outsideProject) }
        let root = projectRoot.resolvingSymlinksInPath()
        let url = projectRoot.appendingPathComponent(relative)
        // Resolve the deepest ancestor that exists, then append the rest, so a not-yet-created file still checks out.
        var existing = url
        var tail: [String] = []
        while !FileManager.default.fileExists(atPath: existing.path), existing.pathComponents.count > 1 {
            tail.insert(existing.lastPathComponent, at: 0)
            existing = existing.deletingLastPathComponent()
        }
        var resolved = existing.resolvingSymlinksInPath()
        for part in tail { resolved.appendPathComponent(part) }
        let rootParts = root.pathComponents, resolvedParts = resolved.pathComponents
        guard resolvedParts.count >= rootParts.count, Array(resolvedParts.prefix(rootParts.count)) == rootParts else {
            return .failure(.outsideProject)
        }
        let inside = resolvedParts.dropFirst(rootParts.count)
        // Folder names compare case-insensitively (APFS and HFS+ volumes usually are), and a project that itself lives inside
        // a `.claude` or `.git` folder is as protected as one beside them.
        let names: Set<String> = [".claude", ".git"]
        func isProtectedName(_ part: some StringProtocol) -> Bool { names.contains(part.lowercased()) }
        let isProtected = relative.split(separator: "/").contains(where: isProtectedName) || inside.contains(where: isProtectedName)
            || rootParts.contains(where: isProtectedName) || projectRoot.pathComponents.contains(where: isProtectedName)
        return .success((relative, url, isProtected))
    }

    /// Why a plugin may not write `path` now, or nil when it may.
    public func pluginWriteRefusal(for path: String) -> PluginWriteRefusal? {
        switch pluginResolve(path) {
        case .failure(let refusal): return refusal
        case .success(let target):
            if target.protected { return .protectedPath }
            if document(target.relative)?.isDirty == true { return .dirty }
            if overlapIndex.hasProposal(path: target.relative) { return .claudeEditing }
            return nil
        }
    }
}
