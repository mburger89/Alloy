import Foundation

extension GitService {
    private static func isZero(_ oid: String) -> Bool { oid.allSatisfy { $0 == "0" } }

    /// The oid of the HEAD blob that gutter marks and hunk actions diff a buffer against, or nil when the file has none
    /// worth diffing: untracked, ignored, unmerged, new in the index, a symlink or a submodule, an unborn HEAD, or no
    /// repository. A file with no status entry is clean, and its blob is looked up once per commit.
    public func headBlobOID(path: String) async -> String? {
        await discover()
        guard state == .ready, let top = repoTop, let status, !status.isUnborn, let head = status.oid else { return nil }
        if let entry = status.entries[path] {
            guard entry.kind == .ordinary || entry.kind == .renamed, !entry.isSubmodule else { return nil }
            let modes = [entry.headMode, entry.indexMode, entry.worktreeMode]
            guard !modes.contains("120000"), !modes.contains("160000") else { return nil }
            guard let oid = entry.headOID, !Self.isZero(oid) else { return nil }
            return oid
        }
        let key = head + ":" + path
        if let cached = headBlobCache[key] { return cached.isEmpty ? nil : cached }
        let r = await run(["ls-tree", "-z", head, "--", prefix + path], in: top, readOnly: true)
        var found = ""
        if r.status == 0, let record = String(decoding: r.stdout, as: UTF8.self).split(separator: "\0").first,
           let tab = record.firstIndex(of: "\t") {
            let fields = record[..<tab].split(separator: " ").map(String.init)
            if fields.count == 3, fields[1] == "blob", fields[0] != "120000" { found = fields[2] }
        }
        if headBlobCache.count >= 512 { headBlobCache = [:] }
        headBlobCache[key] = found
        return found.isEmpty ? nil : found
    }

    /// The oid of the index blob of `path`: the status entry's, or HEAD's when the file is clean. Nil when there is none.
    public func indexBlobOID(path: String) async -> String? {
        await discover()
        if let entry = status?.entries[path] {
            guard entry.kind == .ordinary || entry.kind == .renamed, let oid = entry.indexOID, !Self.isZero(oid) else { return nil }
            return oid
        }
        return await headBlobOID(path: path)
    }
}
