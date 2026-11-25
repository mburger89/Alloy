import Foundation
import Observation

public struct FileTreeEntry: Hashable, Sendable {
    /// Repo-relative path; also the row's identity.
    public let path: String
    public let name: String
    public let isFolder: Bool
}

public struct FileTreeRow: Hashable, Sendable {
    public let entry: FileTreeEntry
    public let depth: Int
}

/// Who touched a file or folder: a file shows its last author, a folder the author all its marked descendants share.
public enum ChangeMark: Hashable, Sendable {
    case author(Author), mixed

    /// A file's mark is its last author; a folder's is the author every marked descendant shares, else `.mixed`.
    public static func marks(for changed: [ChangedFile]) -> [String: ChangeMark] {
        var result: [String: ChangeMark] = [:]
        for file in changed {
            guard let author = file.authors.last else { continue }
            result[file.path] = .author(author)
            var folder = FileTreeSnapshot.parentPath(file.path)
            while !folder.isEmpty {
                let merged: ChangeMark
                switch result[folder] {
                case nil: merged = .author(author)
                case .author(let a)? where a == author: merged = .author(a)
                default: merged = .mixed
                }
                // Unchanged means every folder above already carries this answer.
                if result[folder] == merged { break }
                result[folder] = merged
                folder = FileTreeSnapshot.parentPath(folder)
            }
        }
        return result
    }
}

/// The tree of a project's files, built once from FileIndex's paths. Immutable; ``FileTreeModel`` swaps it whole.
public struct FileTreeSnapshot: Sendable, Equatable {
    private let byFolder: [String: [FileTreeEntry]]
    public let truncated: Bool

    /// Folders come from the file paths only, so there are no empty folders. Per folder: folders first, then files,
    /// each by `name.lowercased()` then `name`.
    public static func build(paths: [String], truncated: Bool) -> FileTreeSnapshot {
        var children: [String: [FileTreeEntry]] = [:]
        var folders: Set<String> = [""]
        for path in paths where !path.isEmpty {
            let parent = Self.parentPath(path)
            // Register the chain of folders above the file once; a known folder ends the climb.
            var folder = parent
            while folders.insert(folder).inserted {
                let up = Self.parentPath(folder)
                children[up, default: []].append(FileTreeEntry(path: folder, name: Self.lastName(folder), isFolder: true))
                folder = up
            }
            children[parent, default: []].append(FileTreeEntry(path: path, name: Self.lastName(path), isFolder: false))
        }
        for key in Array(children.keys) {
            guard let entries = children[key] else { continue }
            children[key] = entries
                .map { (entry: $0, lower: $0.name.lowercased()) }
                .sorted { l, r in
                    if l.entry.isFolder != r.entry.isFolder { return l.entry.isFolder }
                    return l.lower != r.lower ? l.lower < r.lower : l.entry.name < r.entry.name
                }
                .map(\.entry)
        }
        return FileTreeSnapshot(byFolder: children, truncated: truncated)
    }

    /// "" is the root.
    public func children(of folder: String) -> [FileTreeEntry] { byFolder[folder] ?? [] }

    /// Whether `path` is a file or folder of the tree.
    public func contains(_ path: String) -> Bool {
        children(of: Self.parentPath(path)).contains { $0.path == path }
    }

    /// Whether `path` is a folder of the tree.
    public func isFolder(_ path: String) -> Bool {
        children(of: Self.parentPath(path)).contains { $0.path == path && $0.isFolder }
    }

    /// The folder holding `path` ("" at the top level); nil for the root.
    public func parent(of path: String) -> String? { path.isEmpty ? nil : Self.parentPath(path) }

    static func parentPath(_ path: String) -> String {
        guard let slash = path.utf8.lastIndex(of: UInt8(ascii: "/")) else { return "" }
        return String(path[..<slash])
    }

    private static func lastName(_ path: String) -> String {
        guard let slash = path.utf8.lastIndex(of: UInt8(ascii: "/")) else { return path }
        return String(path[path.index(after: slash)...])
    }
}

/// One folder's open state. Each folder has its own object, so toggling one wakes only the rows that read it.
@MainActor @Observable
public final class FolderExpansion {
    public var isExpanded = false
    init() {}
}

/// What the file tree view reads. Rows are laid out only for expanded folders, so a huge tree costs nothing until
/// the user opens it.
@MainActor @Observable
public final class FileTreeModel {
    public private(set) var snapshot = FileTreeSnapshot.build(paths: [], truncated: false)
    /// Change marks by path. Recomputed only when the changed files differ, never by a tree rebuild.
    public private(set) var marks: [String: ChangeMark] = [:]
    @ObservationIgnored private var expansions: [String: FolderExpansion] = [:]
    @ObservationIgnored private var lastPaths: [String] = []
    @ObservationIgnored private var lastTruncated = false
    @ObservationIgnored private var lastChanges: [ChangedFile] = []
    @ObservationIgnored private var generation = 0
    /// Counters tests read: tree builds that ran, and mark computations.
    @ObservationIgnored private(set) var buildCount = 0
    @ObservationIgnored private(set) var marksComputeCount = 0
    /// Called after a new snapshot is installed.
    @ObservationIgnored var snapshotDidChange: (() -> Void)?

    public init() {}

    /// The open state of one folder, created on first use.
    public func expansion(for path: String) -> FolderExpansion {
        if let e = expansions[path] { return e }
        let e = FolderExpansion()
        expansions[path] = e
        return e
    }

    /// The open folders, for persistence.
    public var expandedPaths: Set<String> {
        get { Set(expansions.filter { $0.value.isExpanded }.keys) }
        set {
            for (path, e) in expansions where e.isExpanded && !newValue.contains(path) { e.isExpanded = false }
            for path in newValue { let e = expansion(for: path); if !e.isExpanded { e.isExpanded = true } }
        }
    }

    public func visibleRows() -> [FileTreeRow] {
        var rows: [FileTreeRow] = []
        func walk(_ folder: String, _ depth: Int) {
            for entry in snapshot.children(of: folder) {
                rows.append(FileTreeRow(entry: entry, depth: depth))
                if entry.isFolder, expansion(for: entry.path).isExpanded { walk(entry.path, depth + 1) }
            }
        }
        walk("", 0)
        return rows
    }

    /// Opens every folder above `path` and returns its row index, or nil when the tree has no such path.
    public func reveal(_ path: String) -> Int? {
        let parent = snapshot.parent(of: path) ?? ""
        guard snapshot.children(of: parent).contains(where: { $0.path == path }) else { return nil }
        var up = parent
        while !up.isEmpty {
            let e = expansion(for: up)
            if !e.isExpanded { e.isExpanded = true }
            up = snapshot.parent(of: up) ?? ""
        }
        return visibleRows().firstIndex { $0.entry.path == path }
    }

    /// Recomputes the marks when the changed files differ from the last call.
    public func setChanges(_ files: [ChangedFile]) {
        guard files != lastChanges else { return }
        lastChanges = files
        marksComputeCount += 1
        marks = ChangeMark.marks(for: files)
    }

    /// Builds the new tree off the main actor, and only when the paths differ from the last build. A slower, older
    /// build never overwrites a newer one.
    func update(paths: [String], truncated: Bool) async {
        generation += 1
        let mine = generation
        let old = lastPaths, oldTruncated = lastTruncated
        let built = await Task.detached(priority: .userInitiated) { () -> FileTreeSnapshot? in
            if paths == old, truncated == oldTruncated { return nil }
            return FileTreeSnapshot.build(paths: paths, truncated: truncated)
        }.value
        guard mine == generation, let built else { return }
        buildCount += 1
        lastPaths = paths
        lastTruncated = truncated
        snapshot = built
        snapshotDidChange?()
    }
}
