import CryptoKit
import Foundation

public struct SavedTheme: Equatable, Sendable {
    public var id: String
    public var name: String
    public var url: URL
    public var renamed: Bool
}

public enum ThemeStoreError: Error, Equatable, Sendable {
    case noFreeName(String)
}

/// Saves user theme files into the themes folder. A session may only overwrite files it wrote and that
/// still have the bytes it wrote (Ruling 8); the owners file lives outside the watched folder.
public struct ThemeStore: Sendable {
    public let directory: URL
    private let ownersURL: URL

    public init(appSupport: URL) {
        directory = ThemeLibrary.userDirectory(appSupport: appSupport)
        ownersURL = appSupport.appendingPathComponent("Alloy", isDirectory: true)
            .appendingPathComponent("theme-owners.json")
    }

    private struct Owner: Codable {
        var session: String
        var sha256: String
    }

    /// Lowercase ASCII letters and digits; every other run becomes `-`; trimmed; at most 64 characters.
    public static func slug(_ name: String) -> String {
        var out = ""
        var pendingDash = false
        for byte in name.utf8 {
            let lowered = (byte >= 65 && byte <= 90) ? byte + 32 : byte
            if (lowered >= 97 && lowered <= 122) || (lowered >= 48 && lowered <= 57) {
                if pendingDash && !out.isEmpty { out.append("-") }
                pendingDash = false
                out.append(Character(UnicodeScalar(lowered)))
            } else {
                pendingDash = true
            }
        }
        let trimmed = String(out.prefix(64)).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return trimmed.isEmpty ? "theme" : trimmed
    }

    private static func hash(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func readOwners() -> [String: Owner] {
        guard let data = try? Data(contentsOf: ownersURL),
              let owners = try? JSONDecoder().decode([String: Owner].self, from: data) else { return [:] }
        return owners
    }

    private func writeOwners(_ owners: [String: Owner]) throws {
        try FileManager.default.createDirectory(at: ownersURL.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(owners).write(to: ownersURL, options: .atomic)
    }

    private func fileURL(_ stem: String) -> URL { directory.appendingPathComponent(stem + ".json") }

    private func owns(stem: String, session: UUID, owners: [String: Owner]) -> Bool {
        guard let owner = owners[stem], owner.session == session.uuidString,
              let data = try? Data(contentsOf: fileURL(stem)) else { return false }
        return Self.hash(data) == owner.sha256
    }

    /// True when `id` (`user/<stem>`) was written by `session` and is byte-identical to what it wrote.
    public func owns(_ id: String, session: UUID) -> Bool {
        guard id.hasPrefix("user/") else { return false }
        return owns(stem: String(id.dropFirst(5)), session: session, owners: readOwners())
    }

    /// Holds an exclusive cross-process lock (flock) for the duration of `body`.
    private func withLock<T>(_ body: () throws -> T) throws -> T {
        try FileManager.default.createDirectory(at: ownersURL.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        let lockPath = ownersURL.deletingLastPathComponent().appendingPathComponent("theme-owners.lock").path
        let fd = open(lockPath, O_CREAT | O_RDWR, 0o644)
        guard fd >= 0 else { throw CocoaError(.fileWriteUnknown) }
        defer { close(fd) }
        while flock(fd, LOCK_EX) != 0 {
            if errno != EINTR { throw CocoaError(.fileWriteUnknown) }
        }
        defer { flock(fd, LOCK_UN) }
        return try body()
    }

    public func save(_ file: ThemeFile, name: String, session: UUID, builtIns: [ThemeEntry]) throws -> SavedTheme {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = trimmed.isEmpty ? "Theme" : trimmed
        let baseStem = Self.slug(base)
        let reservedIDs = Set(builtIns.map(\.id))
        let reservedSlugs = Set(builtIns.map { Self.slug($0.file.name) })
        let fm = FileManager.default

        return try withLock {
            var owners = readOwners()
            for attempt in 1...99 {
                let candidate = attempt == 1 ? base : "\(base) \(attempt)"
                var stem = baseStem
                if attempt > 1 {
                    // Cut the base before adding the suffix so every attempt gets a distinct stem.
                    let suffix = "-\(attempt)"
                    stem = String(baseStem.prefix(64 - suffix.count))
                        .trimmingCharacters(in: CharacterSet(charactersIn: "-")) + suffix
                }
                let lowered = candidate.lowercased()
                if reservedIDs.contains(stem) || reservedIDs.contains(lowered)
                    || reservedSlugs.contains(stem) || reservedSlugs.contains(lowered) { continue }
                let url = fileURL(stem)
                if fm.fileExists(atPath: url.path), !owns(stem: stem, session: session, owners: owners) { continue }

                var final = file
                final.name = candidate
                let bytes = try final.encoded()
                try fm.createDirectory(at: directory, withIntermediateDirectories: true)
                try bytes.write(to: url, options: .atomic)
                owners[stem] = Owner(session: session.uuidString, sha256: Self.hash(bytes))
                try writeOwners(owners)
                return SavedTheme(id: "user/" + stem, name: candidate, url: url, renamed: attempt > 1)
            }
            throw ThemeStoreError.noFreeName(base)
        }
    }
}
