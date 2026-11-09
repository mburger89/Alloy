import Foundation

/// Two parties changing the same lines back and forth, for Task 7's UI to show.
///
/// Alerts are live-only on purpose: they are never persisted. An alert describes the last ten minutes of edits,
/// which a restart makes stale, and the history that raised it is held in memory only.
public struct TugAlert: Identifiable, Equatable, Sendable {
    public var id: UUID
    public var path: String
    /// The lines in dispute, as of the latest edit that took part.
    public var lines: ClosedRange<Int>
    /// The two parties, the latest editor first.
    public var parties: [Author]
    public var latest: Author
    /// The last activity: the latest edit that took part.
    public var date: Date
    /// The session that was told to stop edited those lines again. Set at most once.
    public var escalated: Bool
}

/// Detection constants and wording.
enum TugOfWar {
    /// The window for A -> B -> A, for how long an alert lives without activity, and for an ignored stop.
    static let window: TimeInterval = 600
    static let maxAlerts = 50
    /// History kept per file, so a very busy file stays bounded.
    static let maxHistory = 200

    /// A name or path as data for the message: one line, no double quotes (the template quotes the name), no control
    /// characters at all, so nothing inside it can end the quoted name or fake a line.
    static func clean(_ s: String) -> String {
        let stripped = String(String.UnicodeScalarView(s.unicodeScalars.filter { $0.value >= 0x20 && $0.value != 0x7F || $0.properties.isWhitespace }))
        let flat = AlreadyRead.oneLine(stripped)
        // Whitespace controls (tab, vertical tab) survive `oneLine`'s line split; they become plain spaces.
        return String(String.UnicodeScalarView(flat.unicodeScalars.map { $0.value < 0x20 ? " " : $0 }))
    }

    static func stopText(lines: ClosedRange<Int>, path: String, other: String) -> String {
        "Lines \(lines.lowerBound)\u{2013}\(lines.upperBound) of \(clean(path)) are going back and forth between you and \"\(clean(other))\". Leave them as they are now and move on with the rest of your task."
    }

    /// Where an old line number sits after `hunks` were applied. A line inside a hunk follows its context line or
    /// lands where its deleted text was; lines after a hunk move by the hunk's size change. A pure insert
    /// (`oldLines == 0`) follows the unified-diff convention: `oldStart` is the line after which the new lines go,
    /// so that line stays and only later ones move.
    static func remap(_ line: Int, _ hunks: [PatchHunk]) -> Int {
        var delta = 0
        for h in hunks.sorted(by: { $0.oldStart < $1.oldStart }) {
            if h.oldLines == 0 {
                if line > h.oldStart { delta += h.newLines; continue }
                break
            }
            let start = max(1, h.oldStart)
            if line >= start + h.oldLines { delta += h.newLines - h.oldLines; continue }
            if line < start { break }
            // For a pure delete `newStart` is the line before the gap, so the text after it starts one later.
            var o = start, n = h.newLines == 0 ? h.newStart + 1 : max(1, h.newStart)
            for l in h.lines {
                if l.hasPrefix("+") { n += 1; continue }
                if o == line { return h.newLines == 0 ? n : min(n, h.newStart + h.newLines - 1) }
                o += 1
                if !l.hasPrefix("-") { n += 1 }
            }
            break
        }
        return max(1, line + delta)
    }

    static func remap(_ r: ClosedRange<Int>, _ hunks: [PatchHunk]) -> ClosedRange<Int> {
        let lo = remap(r.lowerBound, hunks), hi = remap(r.upperBound, hunks)
        return lo...max(lo, hi)
    }
}

/// In-memory bookkeeping behind `Workspace.tugAlerts`. Main actor only (it lives on the workspace).
struct TugState {
    /// One recorded edit as the detector sees it: who, when and which lines it occupied. Kept and reverted edits stay:
    /// the lines really did flip. Line numbers are moved by every later edit's hunks, so they follow the text.
    struct Entry { var id: UUID; var author: Author; var date: Date; var lines: [ClosedRange<Int>] }
    /// A stop that was decided on for (path, latest, other) near `lines`; `sent` is false when the latest editor was
    /// the user (nobody to tell). It outlives its alert (keeping the edits clears the alert, not the memory of the
    /// stop) and expires ten minutes after the last activity.
    struct Told { var path: String; var latest: Author; var other: Author; var lines: ClosedRange<Int>
                  var alert: UUID; var date: Date; var last: Date; var sent: Bool
                  /// The stop message's id, and when the CLI echoed it (the session took it up). Live-only, like the alerts.
                  var messageID: UUID? = nil; var seenAt: Date? = nil }
    /// `newest` is the latest edit that took part: keeping, reverting or committing it clears the alert.
    struct Meta { var newest: UUID }

    var history: [String: [Entry]] = [:]
    var seen: Set<UUID> = []
    var told: [Told] = []
    var meta: [UUID: Meta] = [:]
}

extension Workspace {
    /// Marks every edit of `path` as already seen, without detecting (a ledger just loaded from disk).
    func markTugSeen(_ path: String) {
        for e in ledger.files[path]?.edits ?? [] { tug.seen.insert(e.id) }
    }

    /// Drops alerts with no activity for ten minutes, and stop memories likewise. Time passing raises no event, so the
    /// UI calls this when it refreshes (a scan also does it); it never touches the disk.
    public func pruneTugAlerts() {
        let t = now()
        let gone = tugAlerts.filter { t.timeIntervalSince($0.date) > TugOfWar.window }.map(\.id)
        if !gone.isEmpty { removeTugAlerts(Set(gone)) }
        tug.told.removeAll { t.timeIntervalSince($0.last) > TugOfWar.window }
    }

    private func removeTugAlerts(_ ids: Set<UUID>) {
        tugAlerts.removeAll { ids.contains($0.id) }
        for id in ids { tug.meta[id] = nil }
    }

    /// Called after the ledger of `path` changed (an edit recorded, kept, reverted or committed). Uses only the
    /// in-memory ledger and the overlap index, never the disk.
    ///
    /// Limitation: edits that arrive in one batch (the same scan) are all located by the ledger's current text, so an
    /// earlier edit of the batch that a later one overwrote has no lines and takes no part in detection. Edits are
    /// normally recorded one at a time (a tool_result, a save, an outside change each go through here on their own).
    func scanTugOfWar(_ path: String) {
        pruneTugAlerts()
        guard let file = ledger.files[path] else { return }
        for e in file.edits where !tug.seen.contains(e.id) {
            tug.seen.insert(e.id)
            // Every recorded edit, `.outside` included, moves the lines of the earlier ones.
            if var h = tug.history[path], !e.hunks.isEmpty {
                for i in h.indices { h[i].lines = h[i].lines.map { TugOfWar.remap($0, e.hunks) } }
                tug.history[path] = h
            }
            if !e.hunks.isEmpty {
                // Alerts and stop memories follow the text too, or an insert above a tug in progress would start a new one.
                for i in tugAlerts.indices where tugAlerts[i].path == path { tugAlerts[i].lines = TugOfWar.remap(tugAlerts[i].lines, e.hunks) }
                for i in tug.told.indices where tug.told[i].path == path { tug.told[i].lines = TugOfWar.remap(tug.told[i].lines, e.hunks) }
            }
            guard e.author != .outside else { continue }
            let lines = e.state == .live ? overlapIndex.runs(path: path, edit: e.id) : []
            if !lines.isEmpty { detectTug(path: path, edit: e, lines: lines) }
            var h = tug.history[path] ?? []
            h.append(TugState.Entry(id: e.id, author: e.author, date: e.date, lines: lines))
            let cutoff = e.date.addingTimeInterval(-TugOfWar.window)
            h.removeAll { $0.date < cutoff }
            if h.count > TugOfWar.maxHistory { h.removeFirst(h.count - TugOfWar.maxHistory) }
            tug.history[path] = h
        }
        // Once the newest edit of an alert is kept, reverted or committed there is nothing left to act on.
        let live = Set(file.edits.filter { $0.state == .live }.map(\.id))
        let done = tugAlerts.filter { $0.path == path && !(tug.meta[$0.id].map { live.contains($0.newest) } ?? false) }.map(\.id)
        if !done.isEmpty { removeTugAlerts(Set(done)) }
    }

    private func detectTug(path: String, edit n: EditRecord, lines: [ClosedRange<Int>]) {
        let x = n.author
        func near(_ a: [ClosedRange<Int>], _ b: [ClosedRange<Int>]) -> Bool {
            a.contains { r in b.contains { OverlapIndex.near(r, $0) } }
        }
        let cutoff = n.date.addingTimeInterval(-TugOfWar.window)
        let overlapping = (tug.history[path] ?? []).filter { $0.date >= cutoff && near($0.lines, lines) }
        // A -> B -> A: the newest earlier overlapping edit by someone else, and an older one by X still.
        guard let yi = overlapping.lastIndex(where: { $0.author != x }),
              overlapping[..<yi].contains(where: { $0.author == x && near($0.lines, overlapping[yi].lines) })
        else { return }
        let y = overlapping[yi]

        // The cluster of this edit's runs that meets the other party's lines.
        let mine = lines.filter { r in y.lines.contains { OverlapIndex.near(r, $0) } }
        let used = mine.isEmpty ? lines : mine
        let hull = used.map(\.lowerBound).min()!...used.map(\.upperBound).max()!
        let parties: Set<Author> = [x, y.author]
        let nowDate = now()

        // An alert is the same one while its lines still meet: a tug that drifts across any fixed boundary stays one.
        let alertIndex: Int
        let existed: Bool
        if let i = tugAlerts.firstIndex(where: { $0.path == path && Set($0.parties) == parties && OverlapIndex.near($0.lines, hull) }) {
            tugAlerts[i].date = n.date
            tugAlerts[i].latest = x
            tugAlerts[i].parties = [x, y.author]
            tugAlerts[i].lines = min(tugAlerts[i].lines.lowerBound, hull.lowerBound)...max(tugAlerts[i].lines.upperBound, hull.upperBound)
            alertIndex = i
            existed = true
        } else {
            tugAlerts.append(TugAlert(id: UUID(), path: path, lines: hull, parties: [x, y.author], latest: x, date: n.date, escalated: false))
            if tugAlerts.count > TugOfWar.maxAlerts {
                removeTugAlerts(Set(tugAlerts.prefix(tugAlerts.count - TugOfWar.maxAlerts).map(\.id)))
            }
            alertIndex = tugAlerts.count - 1
            existed = false
            tugNotice(tugAlerts[alertIndex], kind: .warning)
        }
        let id = tugAlerts[alertIndex].id
        armWarningExpiry()
        tug.meta[id] = TugState.Meta(newest: n.id)

        if let t = tug.told.firstIndex(where: { $0.path == path && $0.latest == x && $0.other == y.author && OverlapIndex.near($0.lines, hull) }) {
            // Already told (possibly for an alert since cleared): never again. The alert escalates, once, only when the
            // session has taken the stop up (the CLI echoed it: a queued message cannot reach the model before then, so
            // earlier edits are not ignoring anything), the alert still stands, and this edit lands on the told lines
            // themselves (no margin: a session that obeys may still touch the lines next to them). An alert the user
            // cleared (kept, reverted, committed) comes back as a plain warning.
            let told = tug.told[t]
            if existed, told.sent, let seen = told.seenAt, n.date >= seen,
               lines.contains(where: { $0.lowerBound <= told.lines.upperBound && told.lines.lowerBound <= $0.upperBound }) {
                let first = !tugAlerts[alertIndex].escalated
                tugAlerts[alertIndex].escalated = true
                if first { tugNotice(tugAlerts[alertIndex], kind: .error) }
            }
            tug.told[t].last = nowDate
            tug.told[t].alert = id
            tug.told[t].lines = min(tug.told[t].lines.lowerBound, hull.lowerBound)...max(tug.told[t].lines.upperBound, hull.upperBound)
        } else {
            tell(latest: x, other: y.author, lines: hull, path: path, alert: id, date: nowDate)
        }
    }

    /// The CLI echoed message `uuid`: if it is a stop, its session has taken it up from now on.
    func noteTugEcho(uuid: String?) {
        guard let uuid, let u = UUID(uuidString: uuid), let i = tug.told.firstIndex(where: { $0.messageID == u }),
              tug.told[i].seenAt == nil else { return }
        tug.told[i].seenAt = now()
    }

    /// Sends the stop message to the latest editor and remembers it. The user is never messaged.
    private func tell(latest: Author, other: Author, lines: ClosedRange<Int>, path: String, alert: UUID, date: Date) {
        var told = TugState.Told(path: path, latest: latest, other: other, lines: lines, alert: alert, date: date, last: date, sent: false)
        defer { tug.told.append(told) }
        // With sharing off the user does not want Alloy writing into sessions: the alert shows, nothing is sent.
        guard case .session(let sid) = latest, session(sid) != nil, settings.shareKnowledge else { return }
        let otherName: String
        switch other {
        case .session(let id): otherName = session(id)?.name ?? "another session"
        default: otherName = "the user"
        }
        told.sent = true
        told.messageID = deliverSystemMessage(to: sid, text: TugOfWar.stopText(lines: lines, path: path, other: otherName))
    }
}
