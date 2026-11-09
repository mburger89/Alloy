import Foundation

/// Advisory "I'm working on this" markers. They never block anything; they only show up in other sessions' overlap
/// messages and in `sessions_changes`.
public enum Claims {
    /// A claim ends this long after its claimant last edited the file (or made the claim).
    public static let expiry: TimeInterval = 10 * 60
    /// Most claims one session keeps; the oldest go first.
    public static let perSessionLimit = 20
    /// Longest note kept, in characters.
    public static let noteLimit = 200
    /// Highest line number a claim may name.
    public static let maxLine = 10_000_000
}

public struct Claim: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var session: UUID
    /// Project-relative, as the ledger keys it.
    public var path: String
    public var lines: ClosedRange<Int>
    public var note: String
    /// The claim, or the claimant's last edit of the file: expiry counts from here.
    public var refreshed: Date
}

extension Workspace {
    var claimsURL: URL { storeDirectory.appendingPathComponent("claims.json") }

    /// Claims that have not expired. Drops the expired ones as a side effect.
    func activeClaims() -> [Claim] {
        let cutoff = now().addingTimeInterval(-Claims.expiry)
        guard claims.contains(where: { $0.refreshed < cutoff }) else { return claims }
        claims.removeAll { $0.refreshed < cutoff }
        persistClaims()
        return claims
    }

    /// Records (or updates) a claim. A repeat of the same lines replaces the earlier one.
    func addClaim(session: UUID, path: String, lines: ClosedRange<Int>, note: String) {
        _ = activeClaims()
        claims.removeAll { $0.session == session && $0.path == path && $0.lines == lines }
        claims.append(Claim(id: UUID(), session: session, path: path, lines: lines,
                            note: String(AlreadyRead.oneLine(note).prefix(Claims.noteLimit)), refreshed: now()))
        let mine = claims.indices.filter { claims[$0].session == session }
        if mine.count > Claims.perSessionLimit {
            let drop = Set(mine.prefix(mine.count - Claims.perSessionLimit))
            claims = claims.enumerated().filter { !drop.contains($0.offset) }.map(\.element)
        }
        persistClaims()
    }

    /// Removes the session's claims on `path` that touch `lines` (all of them when nil). Returns how many went.
    @discardableResult
    func releaseClaims(session: UUID, path: String, lines: ClosedRange<Int>?) -> Int {
        _ = activeClaims()
        let before = claims.count
        claims.removeAll { c in
            c.session == session && c.path == path && (lines.map { $0.overlaps(c.lines) } ?? true)
        }
        if claims.count != before { persistClaims() }
        return before - claims.count
    }

    /// A session stopped or exited: its claims go with it.
    func dropClaims(session: UUID) {
        guard claims.contains(where: { $0.session == session }) else { return }
        claims.removeAll { $0.session == session }
        persistClaims()
    }

    /// The claimant edited `path`: its claims there start their expiry again.
    func refreshClaims(session: UUID, path: String) {
        _ = activeClaims()
        var changed = false
        for i in claims.indices where claims[i].session == session && claims[i].path == path {
            claims[i].refreshed = now(); changed = true
        }
        if changed { persistClaims() }
    }

    /// Other sessions' claims on `path` that touch `spans` or lie within `Overlap.margin` lines of one; every claim
    /// on the file when `spans` is nil (the hook could not place the change).
    func claimItems(for session: UUID, path: String, spans: [ClosedRange<Int>]?) -> [OverlapNotice.Item] {
        activeClaims().filter { c in
            guard c.session != session, c.path == path else { return false }
            guard let spans else { return true }
            return spans.contains { s in
                c.lines.lowerBound <= s.upperBound + Overlap.margin && s.lowerBound <= c.lines.upperBound + Overlap.margin
            }
        }.map { c in
            let who = TugOfWar.clean(self.session(c.session)?.name ?? "Another session")
            let note = c.note.isEmpty ? "" : ": \"\(TugOfWar.clean(c.note))\""
            return OverlapNotice.Item(key: "claim:\(c.id.uuidString)",
                                      text: "\"\(who)\" has claimed \"\(TugOfWar.clean(path))\" \(OverlapNotice.span(c.lines))\(note)")
        }
    }

    /// Writes `claims.json` off the main actor, chained and coalesced like `persistNotes`.
    func persistClaims() {
        claimsSnapshot = claims
        guard !claimsWriteQueued else { return }
        claimsWriteQueued = true
        let url = claimsURL, previous = claimsWrite
        claimsWrite = Task.detached { [weak self] in
            await previous?.value
            guard let snapshot = await self?.takeClaimsSnapshot() else { return }
            do {
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try JSONEncoder().encode(snapshot).write(to: url, options: .atomic)
            } catch {
                await self?.report("Could not save claims: \(error.localizedDescription)")
            }
        }
    }

    private func takeClaimsSnapshot() -> [Claim]? {
        claimsWriteQueued = false
        defer { claimsSnapshot = nil }
        return claimsSnapshot
    }
}
