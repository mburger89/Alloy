import Foundation

/// How a path shows in the file tree. Higher raw values are stronger when a folder rolls up its children.
public enum GitDisplayStatus: Int, Comparable, Sendable {
    case ignored, untracked, renamed, added, modified, conflicted

    public static func < (a: GitDisplayStatus, b: GitDisplayStatus) -> Bool { a.rawValue < b.rawValue }
}

/// A merge, rebase or cherry-pick in progress.
public enum GitOperation: String, Sendable {
    case merge, rebase, cherryPick

    /// Looks for the marker files git leaves in `gitDir` while an operation is unfinished.
    public static func detect(gitDir: URL) -> GitOperation? {
        let fm = FileManager.default
        func has(_ name: String) -> Bool { fm.fileExists(atPath: gitDir.appendingPathComponent(name).path) }
        if has("rebase-merge") || has("rebase-apply") { return .rebase }
        if has("MERGE_HEAD") { return .merge }
        if has("CHERRY_PICK_HEAD") { return .cherryPick }
        return nil
    }
}

/// One entry of `git status --porcelain=v2`.
public struct GitFileStatus: Equatable, Sendable {
    public enum Kind: Sendable { case ordinary, renamed, unmerged, untracked, ignored }

    /// Relative to the project (the parser's `prefix` is stripped). A directory entry keeps git's trailing "/".
    public var path: String
    /// The old path of a rename or copy.
    public var origPath: String?
    /// Index and worktree status letters as git prints them; "." means unchanged.
    public var index: Character
    public var worktree: Character
    public var kind: Kind
    public var headOID: String?
    public var indexOID: String?
    public var headMode: String?
    public var indexMode: String?
    public var worktreeMode: String?
    public var isSubmodule: Bool

    public init(path: String, origPath: String? = nil, index: Character = ".", worktree: Character = ".", kind: Kind = .ordinary,
                headOID: String? = nil, indexOID: String? = nil, headMode: String? = nil, indexMode: String? = nil,
                worktreeMode: String? = nil, isSubmodule: Bool = false) {
        self.path = path; self.origPath = origPath; self.index = index; self.worktree = worktree; self.kind = kind
        self.headOID = headOID; self.indexOID = indexOID; self.headMode = headMode; self.indexMode = indexMode
        self.worktreeMode = worktreeMode; self.isSubmodule = isSubmodule
    }

    public var display: GitDisplayStatus {
        switch kind {
        case .unmerged: return .conflicted
        case .untracked: return .untracked
        case .ignored: return .ignored
        case .ordinary, .renamed:
            if index == "A" { return .added }
            if index == "R" || index == "C" { return .renamed }
            return .modified
        }
    }

    /// Whether the index differs from HEAD for this path.
    public var isStaged: Bool {
        (kind == .ordinary || kind == .renamed) && index != "."
    }

    /// Whether the worktree differs from the index (an untracked file counts).
    public var hasWorktreeChange: Bool {
        switch kind {
        case .untracked: true
        case .ignored: false
        case .unmerged: true
        case .ordinary, .renamed: worktree != "."
        }
    }
}

public struct GitStatus: Equatable, Sendable {
    public var branch: String?
    public var oid: String?
    public var isUnborn: Bool
    public var upstream: String?
    public var ahead: Int?
    public var behind: Int?
    public var operation: GitOperation?
    public var entries: [String: GitFileStatus]

    public init(branch: String? = nil, oid: String? = nil, isUnborn: Bool = false, upstream: String? = nil, ahead: Int? = nil,
                behind: Int? = nil, operation: GitOperation? = nil, entries: [String: GitFileStatus] = [:]) {
        self.branch = branch; self.oid = oid; self.isUnborn = isUnborn; self.upstream = upstream
        self.ahead = ahead; self.behind = behind; self.operation = operation; self.entries = entries
    }
}

/// Parses `git status --porcelain=v2 -z --branch --untracked-files=normal --ignored=traditional`.
public enum GitStatusParser {
    /// `prefix` is the project's path inside the repository ("" or "sub/"); it is stripped from every path and
    /// entries outside it are dropped.
    public static func parse(_ data: Data, prefix: String) -> GitStatus {
        var status = GitStatus()
        let fields = data.split(separator: 0, omittingEmptySubsequences: true).map { String(decoding: $0, as: UTF8.self) }
        func relative(_ p: String) -> String? {
            if prefix.isEmpty { return p }
            guard p.hasPrefix(prefix) else { return nil }
            let r = String(p.dropFirst(prefix.count))
            return r.isEmpty ? nil : r
        }
        var i = 0
        while i < fields.count {
            let f = fields[i]; i += 1
            if f.hasPrefix("# ") {
                let parts = f.dropFirst(2).split(separator: " ", maxSplits: 1, omittingEmptySubsequences: false)
                guard parts.count == 2 else { continue }
                let value = String(parts[1])
                switch parts[0] {
                case "branch.oid":
                    if value == "(initial)" { status.isUnborn = true } else { status.oid = value }
                case "branch.head": status.branch = value == "(detached)" ? nil : value
                case "branch.upstream": status.upstream = value
                case "branch.ab":
                    let ab = value.split(separator: " ")
                    if ab.count == 2 { status.ahead = Int(ab[0].dropFirst()); status.behind = Int(ab[1].dropFirst()) }
                default: break
                }
                continue
            }
            guard let tag = f.first else { continue }
            switch tag {
            case "1":
                let p = f.split(separator: " ", maxSplits: 8, omittingEmptySubsequences: false)
                guard p.count == 9, let path = relative(String(p[8])) else { continue }
                let xy = Array(p[1])
                status.entries[path] = GitFileStatus(
                    path: path, index: xy[0], worktree: xy[1], kind: .ordinary, headOID: String(p[6]), indexOID: String(p[7]),
                    headMode: String(p[3]), indexMode: String(p[4]), worktreeMode: String(p[5]), isSubmodule: p[2].first == "S")
            case "2":
                let p = f.split(separator: " ", maxSplits: 9, omittingEmptySubsequences: false)
                guard p.count == 10 else { continue }
                let orig = i < fields.count ? fields[i] : nil
                i += 1
                guard let path = relative(String(p[9])) else { continue }
                let xy = Array(p[1])
                status.entries[path] = GitFileStatus(
                    path: path, origPath: orig.flatMap(relative), index: xy[0], worktree: xy[1], kind: .renamed,
                    headOID: String(p[6]), indexOID: String(p[7]), headMode: String(p[3]), indexMode: String(p[4]),
                    worktreeMode: String(p[5]), isSubmodule: p[2].first == "S")
            case "u":
                let p = f.split(separator: " ", maxSplits: 10, omittingEmptySubsequences: false)
                guard p.count == 11, let path = relative(String(p[10])) else { continue }
                let xy = Array(p[1])
                status.entries[path] = GitFileStatus(
                    path: path, index: xy[0], worktree: xy[1], kind: .unmerged, headMode: String(p[3]),
                    worktreeMode: String(p[6]), isSubmodule: p[2].first == "S")
            case "?":
                guard let path = relative(String(f.dropFirst(2))) else { continue }
                status.entries[path] = GitFileStatus(path: path, index: "?", worktree: "?", kind: .untracked)
            case "!":
                guard let path = relative(String(f.dropFirst(2))) else { continue }
                status.entries[path] = GitFileStatus(path: path, index: "!", worktree: "!", kind: .ignored)
            default: break
            }
        }
        return status
    }
}

public enum GitStatusRollup {
    /// Folder statuses from file statuses: each folder takes its strongest non-ignored child. A path ending in "/"
    /// (an untracked directory) colours itself too. An ignored child never colours its parent; each folder in
    /// `ignoredFolders` is ignored for itself only.
    public static func folders(_ files: [String: GitDisplayStatus], ignoredFolders: Set<String>) -> [String: GitDisplayStatus] {
        var out: [String: GitDisplayStatus] = [:]
        for (rawPath, status) in files where status != .ignored {
            let isDir = rawPath.hasSuffix("/")
            let path = isDir ? String(rawPath.dropLast()) : rawPath
            var comps = path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
            if !isDir { comps.removeLast() }
            var folder = ""
            for c in comps {
                folder = folder.isEmpty ? c : folder + "/" + c
                if (out[folder] ?? .ignored) < status { out[folder] = status }
            }
        }
        for f in ignoredFolders {
            let key = f.hasSuffix("/") ? String(f.dropLast()) : f
            if out[key] == nil { out[key] = .ignored }
        }
        return out
    }
}

public enum GitStatusDiff {
    /// Paths whose status appeared, disappeared or changed between two snapshots.
    public static func changedPaths(old: [String: GitDisplayStatus], new: [String: GitDisplayStatus]) -> Set<String> {
        var out = Set<String>()
        for (k, v) in new where old[k] != v { out.insert(k) }
        for k in old.keys where new[k] == nil { out.insert(k) }
        return out
    }
}
