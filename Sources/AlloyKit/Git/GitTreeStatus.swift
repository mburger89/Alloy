import AlloyCore
import Foundation
import Observation

/// One file tree row's git status. A row's label reads only its own cell, so a status change re-runs that row alone.
@MainActor @Observable
public final class GitStatusCell {
    public internal(set) var status: GitDisplayStatus?
    init(status: GitDisplayStatus?) { self.status = status }
}

/// The file tree's git colours: one cell per row that was ever drawn, set only when its value changes. A directory
/// git reports as a whole (an untracked or ignored one) colours everything under it too. The tree never reads this
/// as a whole, so an update that changes one file re-runs one label.
@MainActor
public final class GitTreeStatus {
    @ObservationIgnored private var cells: [String: GitStatusCell] = [:]
    /// What git said, by project-relative path without a trailing slash.
    private var explicit: [String: GitDisplayStatus] = [:]
    /// The subset of `explicit` that colours a whole directory (untracked and ignored ones).
    private var covering: [String: GitDisplayStatus] = [:]

    /// With colours off every cell reads nil; the statuses are kept, so turning them on again needs no git run.
    public var enabled = true {
        didSet { if enabled != oldValue { refreshAll() } }
    }

    public init() {}

    /// The cell of `path` (a row's path as the tree has it), created on first ask with the status known so far.
    public func cell(for path: String) -> GitStatusCell {
        if let c = cells[path] { return c }
        let c = GitStatusCell(status: effective(path))
        cells[path] = c
        return c
    }

    /// Sets the statuses that changed: a value sets or replaces, nil clears. A trailing "/" marks a directory git reports
    /// whole, and an ignored path covers what is under it. Only cells whose value differs are written.
    public func apply(_ changes: [String: GitDisplayStatus?]) {
        var coverChanged: [String] = []
        var touched: [String] = []
        for (rawPath, status) in changes {
            let isDir = rawPath.hasSuffix("/")
            let path = isDir ? String(rawPath.dropLast()) : rawPath
            guard !path.isEmpty else { continue }
            touched.append(path)
            if let status {
                explicit[path] = status
                if isDir || status == .ignored {
                    if covering[path] != status { coverChanged.append(path) }
                    covering[path] = status
                }
            } else {
                explicit[path] = nil
                if covering.removeValue(forKey: path) != nil { coverChanged.append(path) }
            }
        }
        for path in touched { if let c = cells[path] { set(c, effective(path)) } }
        if !coverChanged.isEmpty {
            let prefixes = coverChanged.map { $0 + "/" }
            for (path, c) in cells where prefixes.contains(where: path.hasPrefix) { set(c, effective(path)) }
        }
    }

    private func refreshAll() {
        for (path, c) in cells { set(c, effective(path)) }
    }

    private func set(_ cell: GitStatusCell, _ status: GitDisplayStatus?) {
        if cell.status != status { cell.status = status }
    }

    /// The path's own status, else that of its nearest covering directory.
    private func effective(_ path: String) -> GitDisplayStatus? {
        guard enabled else { return nil }
        if let s = explicit[path] { return s }
        guard !covering.isEmpty else { return nil }
        var dir = path
        while let slash = dir.lastIndex(of: "/") {
            dir = String(dir[..<slash])
            if let s = covering[dir] { return s }
        }
        return nil
    }
}

extension GitDisplayStatus {
    /// The accessibility value of a row.
    var accessibilityName: String {
        switch self {
        case .modified: "git-status-modified"
        case .added: "git-status-added"
        case .renamed: "git-status-renamed"
        case .untracked: "git-status-untracked"
        case .conflicted: "git-status-conflicted"
        case .ignored: "git-status-ignored"
        }
    }
}
