import CryptoKit
import Foundation

public struct ChangedFile: Equatable, Sendable {
    public var path: String
    /// Distinct authors, in order of their first live edit.
    public var authors: [Author]
    public init(path: String, authors: [Author]) { self.path = path; self.authors = authors }
}

/// The file ledgers of one project, keyed by project-relative path.
public struct ProjectLedger: Codable, Sendable, Equatable {
    public let projectRoot: URL
    public var files: [String: FileLedger] = [:]

    public init(projectRoot: URL) { self.projectRoot = projectRoot }

    /// Records a tool result. Ignores paths outside the project root and results that carry no file change.
    @discardableResult
    public mutating func record(_ result: ToolUseResult, author: Author, toolUseID: String?, date: Date) -> [EditRecord] {
        switch result {
        case .edit(let filePath, let originalFile, let hunks):
            guard let rel = relativePath(filePath) else { return [] }
            // The CLI has already written the file, so the pre-edit text is `originalFile`, not what is on disk.
            var ledger = files[rel] ?? FileLedger(path: rel, baseline: originalFile ?? readDisk(filePath) ?? "")
            let recs: [EditRecord]
            if let original = originalFile, ledger.canAdopt(originalFile: original),
               let produced = Self.patched(original, hunks),
               let adopted = ledger.adoptOutside(as: author, originalFile: original, newText: produced, toolUseID: toolUseID) {
                recs = [adopted]
            } else if let applied = ledger.applyPatchChecked(author: author, originalFile: originalFile, hunks: hunks,
                                                      toolUseID: toolUseID, date: date) {
                recs = applied
            } else if let disk = readDisk(filePath) {
                recs = ledger.applyFullText(author: author, newText: disk, toolUseID: toolUseID, date: date).map { [$0] } ?? []
            } else {
                recs = []
            }
            files[rel] = ledger
            return recs
        case .write(let filePath, let isCreate, let content, let originalFile, let hunks):
            guard let rel = relativePath(filePath) else { return [] }
            var ledger = files[rel] ?? FileLedger(path: rel, baseline: isCreate ? "" : (originalFile ?? ""))
            var recs: [EditRecord] = []
            var trial = ledger
            if !isCreate, let original = originalFile, ledger.canAdopt(originalFile: original),
               let adopted = ledger.adoptOutside(as: author, originalFile: original, newText: content, toolUseID: toolUseID) {
                files[rel] = ledger
                return [adopted]
            }
            if !isCreate, originalFile != nil,
               let applied = trial.applyPatchChecked(author: author, originalFile: originalFile, hunks: hunks,
                                                     toolUseID: toolUseID, date: date),
               TextDiff.same(trial.text.text, content) {
                ledger = trial
                recs = applied
            } else {
                recs = ledger.applyFullText(author: author, newText: content, toolUseID: toolUseID, date: date).map { [$0] } ?? []
            }
            files[rel] = ledger
            return recs
        case .message, .other, .none:
            return []
        }
    }

    /// Files with at least one live edit, sorted by path.
    public func changedFiles() -> [ChangedFile] {
        files.keys.sorted().compactMap { path in
            var authors: [Author] = []
            for e in files[path]!.edits where e.state == .live && !authors.contains(e.author) { authors.append(e.author) }
            return authors.isEmpty ? nil : ChangedFile(path: path, authors: authors)
        }
    }

    /// `original` with `hunks` applied, or nil when they do not apply.
    private static func patched(_ original: String, _ hunks: [PatchHunk]) -> String? {
        var tl = TextLines(original)
        guard let lines = try? Patch.apply(hunks, to: tl.lines) else { return nil }
        if tl.lines.isEmpty { tl.hasTrailingNewline = true }
        tl.lines = lines
        return tl.text
    }

    // MARK: Paths

    private func readDisk(_ path: String) -> String? { try? String(contentsOfFile: path, encoding: .utf8) }

    private func relativePath(_ path: String) -> String? { Self.relativePath(path, root: projectRoot) }

    /// The project-relative form of `path` (standardised, symlinks resolved on both sides), or nil outside `root`.
    /// Does file system lookups, so call it off the main actor when many paths are involved.
    static func relativePath(_ path: String, root: URL) -> String? {
        let roots = [root.standardizedFileURL.path, root.resolvingSymlinksInPath().path]
        let url = URL(fileURLWithPath: path)
        let candidates = [url.standardizedFileURL.path, url.resolvingSymlinksInPath().path]
        for root in roots {
            let prefix = root.hasSuffix("/") ? root : root + "/"
            for c in candidates where c.hasPrefix(prefix) && c.count > prefix.count {
                return String(c.dropFirst(prefix.count))
            }
        }
        return nil
    }

    // MARK: Persistence

    /// `<appSupport>/Alloy/Projects/<first 16 hex of sha256(root path)>/ledger.json`
    public static func storeURL(projectRoot: URL, appSupport: URL) -> URL {
        let digest = SHA256.hash(data: Data(projectRoot.path.utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined().prefix(16)
        return appSupport.appendingPathComponent("Alloy/Projects/\(hex)/ledger.json")
    }

    public func save(to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(self).write(to: url, options: .atomic)
    }

    public static func load(from url: URL) throws -> ProjectLedger {
        try JSONDecoder().decode(ProjectLedger.self, from: Data(contentsOf: url))
    }
}
