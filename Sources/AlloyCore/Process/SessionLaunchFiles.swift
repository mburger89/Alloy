import Foundation

/// Per-session files that carry the MCP config and hook settings (which hold the session's bearer token) to the CLI,
/// so the token never appears in the process arguments. Layout: `<support>/Alloy/session-launch/<session-uuid>/`
/// with `mcp.json` and `settings.json`; the directories are 0700 and the files 0600.
public struct SessionLaunchFiles: Sendable {
    public let root: URL

    public init(supportDirectory: URL) {
        root = supportDirectory.appendingPathComponent("Alloy/session-launch", isDirectory: true)
    }

    public struct Paths: Sendable, Equatable {
        public var mcpConfigPath: String?
        public var settingsPath: String?
    }

    private func directory(for id: UUID) -> URL {
        root.appendingPathComponent(id.uuidString.lowercased(), isDirectory: true)
    }

    /// Writes whichever of the two documents is given. Replaces anything left from an earlier run of this session.
    public func write(sessionID: UUID, mcpConfig: String?, settings: String?) throws -> Paths {
        let fm = FileManager.default
        try AlloySettings.ensureSupportDirectory(appSupport: root.deletingLastPathComponent().deletingLastPathComponent())
        try ensureDirectory(root)
        let dir = directory(for: sessionID)
        if fm.fileExists(atPath: dir.path) { try fm.removeItem(at: dir) }
        try ensureDirectory(dir)
        var paths = Paths()
        do {
            if let mcpConfig { paths.mcpConfigPath = try writeFile(mcpConfig, named: "mcp.json", in: dir) }
            if let settings { paths.settingsPath = try writeFile(settings, named: "settings.json", in: dir) }
        } catch {
            try? fm.removeItem(at: dir)
            throw error
        }
        return paths
    }

    /// Deletes this session's files only.
    public func remove(sessionID: UUID) {
        try? FileManager.default.removeItem(at: directory(for: sessionID))
    }

    /// Deletes every session's files (leftovers of a crashed run).
    public func removeAll() {
        try? FileManager.default.removeItem(at: root)
    }

    private func ensureDirectory(_ url: URL) throws {
        var info = stat()
        if lstat(url.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFLNK {
            throw CocoaError(.fileWriteInvalidFileName)
        }
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    }

    private func writeFile(_ text: String, named name: String, in dir: URL) throws -> String {
        let path = dir.appendingPathComponent(name).path
        guard FileManager.default.createFile(atPath: path, contents: Data(text.utf8),
                                             attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
        return path
    }
}
