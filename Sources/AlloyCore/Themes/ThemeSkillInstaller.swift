import Foundation

public enum ThemeSkillStatus: Equatable, Sendable {
    case notInstalled
    case current
    /// Some file is missing or its bytes differ: an older version, or edits made by the user.
    case different
}

public enum ThemeSkillInstallError: Error, Equatable, Sendable, LocalizedError {
    /// A relative path that is empty, absolute or climbs out of the skill directory.
    case unsafePath(String)

    public var errorDescription: String? {
        switch self {
        case .unsafePath(let path): return "\"\(path)\" is not a path inside the skill folder."
        }
    }
}

/// Installs the theme skill into `<home>/.claude/skills/alloy-theme`. This is the only place Alloy writes under
/// `.claude`, and only when the user asks (Settings). The home is injected; tests pass a temporary one.
///
/// The calls are synchronous file I/O and not main-actor bound: call them from a detached task.
public struct ThemeSkillInstaller: Sendable {
    public let directory: URL

    public init(home: URL) {
        directory = home.appendingPathComponent(".claude", isDirectory: true)
            .appendingPathComponent("skills", isDirectory: true)
            .appendingPathComponent("alloy-theme", isDirectory: true)
    }

    public func status(files: [String: String]) -> ThemeSkillStatus {
        let manager = FileManager.default
        var found = 0
        var same = true
        for (path, text) in files {
            guard (try? Self.check(path)) != nil else { return .different }
            guard let existing = manager.contents(atPath: directory.appendingPathComponent(path).path) else {
                same = false
                continue
            }
            found += 1
            if existing != Data(text.utf8) { same = false }
        }
        if found == 0 { return .notInstalled }
        return same ? .current : .different
    }

    /// Installs, but never over files that appeared after the caller read `.notInstalled`: then nothing is written and
    /// `.different` comes back, so the caller can ask the user first. Returns the status after the call.
    public func install(files: [String: String], expecting: ThemeSkillStatus) throws -> ThemeSkillStatus {
        let now = status(files: files)
        if now == .current { return .current }
        if expecting == .notInstalled && now == .different { return .different }
        try install(files: files)
        return status(files: files)
    }

    /// Writes every file atomically inside the skill directory. Files the user added there stay.
    public func install(files: [String: String]) throws {
        for path in files.keys { try Self.check(path) }
        let manager = FileManager.default
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        for (path, text) in files {
            let url = directory.appendingPathComponent(path)
            try manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: url, options: .atomic)
        }
    }

    @discardableResult
    static func check(_ path: String) throws -> String {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        if path.isEmpty || path.hasPrefix("/") || parts.contains(where: { $0 == ".." || $0 == "." || $0.isEmpty }) {
            throw ThemeSkillInstallError.unsafePath(path)
        }
        return path
    }
}
