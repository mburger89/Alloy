import Foundation

/// Something the user may want to know about two parties working on the same lines: an overlap a session was told
/// about, or a tug-of-war. The sidebar markers and the notice strip show these.
public struct CoordinationWarning: Identifiable, Equatable, Sendable {
    public enum Kind: Sendable { case overlap, tug }
    /// A tug warning has its alert's id.
    public var id: UUID
    public var kind: Kind
    /// The sessions involved (the user and outside edits are not sessions).
    public var sessions: [UUID]
    public var path: String
    /// Nil only when the lines are not known.
    public var lines: ClosedRange<Int>?
    /// The last activity.
    public var date: Date
    /// A tug whose stop message was ignored. The only warning that needs the user, so the only red one.
    public var escalated: Bool
    /// One line for hover help and the notice strip. Built from cleaned names and paths.
    public var summary: String
}

/// What the user dismissed: a warning at one level. An escalated tug is a new thing to see, so it is not hidden by
/// the dismissal of the plain tug.
public struct DismissedWarning: Hashable, Sendable {
    public var id: UUID
    public var escalated: Bool
}

/// A stored overlap warning and what clears it.
struct OverlapWarningRecord {
    var warning: CoordinationWarning
    /// The told-once key, so a repeat of the same telling updates this record instead of adding one.
    var key: String
    /// Ledger edits involved: the other party's, and the editing session's own once its tool call is applied.
    var edits: Set<UUID>
    /// Tool call ids whose applied edits join `edits`: the editor's own and the other party's (its proposal or edit).
    var tools: Set<String>
    /// The editing session's own tool call, the one this warning was raised at.
    var editorTool: String = ""
}

struct OverlapNoticeKey: Hashable { let session: Session.ID; let text: String }

extension Workspace {
    /// An overlap warning lives this long without activity (the tug window, 10 minutes).
    static let warningLifetime: TimeInterval = TugOfWar.window
    /// The same overlap notice reaches one session's chat at most once in this long.
    static let overlapNoticeWindow: TimeInterval = 60
    private static let maxOverlapWarnings = 50

    /// The warnings to show now, oldest first: overlap warnings and tug alerts not yet ten minutes old. Reading it
    /// changes nothing, so a view may call it on every refresh; markers clear on keep, revert or commit (the ledger
    /// changing removes them) and, with the injected clock, when ten minutes pass without activity.
    public var coordinationWarnings: [CoordinationWarning] {
        let t = now()
        var out = overlapWarnings.map(\.warning).filter { t.timeIntervalSince($0.date) <= Self.warningLifetime }
        for alert in tugAlerts where t.timeIntervalSince(alert.date) <= Self.warningLifetime { out.append(tugWarning(alert)) }
        return out.sorted { $0.date < $1.date }
    }

    public func coordinationWarnings(involving session: UUID) -> [CoordinationWarning] {
        coordinationWarnings.filter { $0.sessions.contains(session) }
    }

    public func coordinationWarnings(forPath path: String) -> [CoordinationWarning] {
        coordinationWarnings.filter { $0.path == path }
    }

    /// The warning the notice strip shows: an escalated one first, else the newest; not dismissed, and involving a
    /// session other than `selected`.
    public func noticeWarning(selected: UUID?) -> CoordinationWarning? {
        let shown = coordinationWarnings.filter { w in
            !dismissedWarnings.contains(DismissedWarning(id: w.id, escalated: w.escalated)) && w.sessions.contains { $0 != selected }
        }
        return shown.last(where: \.escalated) ?? shown.last
    }

    /// Hides the notice strip for this warning at its current level. The markers stay; they say the overlap is still there.
    public func dismissWarning(_ warning: CoordinationWarning) {
        dismissedWarnings.insert(DismissedWarning(id: warning.id, escalated: warning.escalated))
    }

    // MARK: Expiry

    /// Sleeps (on the injected autosave clock) until the earliest warning expires, then prunes the stored state, which
    /// is observed, so the views drop the markers. One sleeper at a time; it re-arms for the next expiry.
    func armWarningExpiry() {
        guard !isShuttingDown, let oldest = (overlapWarnings.map(\.warning.date) + tugAlerts.map(\.date)).min() else {
            warningSleeper?.cancel(); warningSleeper = nil; warningSleeperExpiry = nil
            return
        }
        let expiry = oldest.addingTimeInterval(Self.warningLifetime)
        if warningSleeper != nil, let armed = warningSleeperExpiry, armed <= expiry { return }
        warningSleeper?.cancel()
        warningSleeperExpiry = expiry
        let clock = autosaveClock
        // Expiry is "more than ten minutes", so wake a second after.
        let deadline = clock.now + max(1, expiry.timeIntervalSince(now()) + 1)
        warningSleeper = Task { @MainActor [weak self] in
            do { try await clock.sleep(until: deadline) } catch { return }
            guard let self, !Task.isCancelled else { return }
            self.warningSleeper = nil; self.warningSleeperExpiry = nil
            self.expireWarnings()
            self.armWarningExpiry()
        }
    }

    func expireWarnings() {
        pruneTugAlerts()
        pruneOverlapWarnings()
        let live = Set(coordinationWarnings.map(\.id))
        if dismissedWarnings.contains(where: { !live.contains($0.id) }) { dismissedWarnings = dismissedWarnings.filter { live.contains($0.id) } }
    }

    /// A tool call that came back as an error (denied or failed) never applied its change: drop the warnings that
    /// came from it, unless the editor already has a live edit in the record.
    func dropWarnings(ofFailedTool tool: String) {
        func isLive(_ id: UUID) -> Bool { editRecord(id: id).map { $0.state == .live } ?? false }
        func editorHasLiveEdit(_ r: OverlapWarningRecord) -> Bool {
            guard let editor = r.warning.sessions.first else { return false }
            return r.edits.contains { id in editRecord(id: id).map { $0.author == .session(editor) && $0.state == .live } ?? false }
        }
        // The editor's own call failing ends the warning unless the editor already has a live edit in the record. The
        // other session's call failing ends it only when neither side has a live edit left in the record.
        func goes(_ r: OverlapWarningRecord) -> Bool {
            guard r.tools.contains(tool) else { return false }
            return tool == r.editorTool ? !editorHasLiveEdit(r) : !r.edits.contains(where: isLive)
        }
        guard overlapWarnings.contains(where: goes) else { return }
        overlapWarnings.removeAll(where: goes)
        armWarningExpiry()
    }

    private func tugWarning(_ a: TugAlert) -> CoordinationWarning {
        func name(_ author: Author) -> String {
            switch author {
            case .session(let id): TugOfWar.clean(session(id)?.name ?? "another session")
            case .user: "you"
            case .outside: "an outside change"
            }
        }
        let range = OverlapNotice.span(a.lines)
        var summary = "\(name(a.parties.first ?? a.latest)) and \(name(a.parties.dropFirst().first ?? a.latest)) keep changing \(TugOfWar.clean(a.path)) \(range) back and forth"
        if a.escalated { summary += "; \(name(a.latest)) went on after being asked to stop" }
        let ids = a.parties.compactMap { p -> UUID? in if case .session(let id) = p { id } else { nil } }
        return CoordinationWarning(id: a.id, kind: .tug, sessions: ids, path: a.path, lines: a.lines, date: a.date,
                                   escalated: a.escalated, summary: summary)
    }

    // MARK: Overlaps

    /// Called after `editor` was told `told` at a PreToolUse: records one warning per telling, and tells the other
    /// session, which would not otherwise hear that its change was touched. The user is not a session and gets nothing.
    func recordOverlapWarnings(editor: Session, path: String, told: [OverlapNotice.Item], lines: ClosedRange<Int>?, tool: String) {
        let date = now()
        pruneOverlapWarnings()
        let editorName = TugOfWar.clean(editor.name), cleanPath = TugOfWar.clean(path)
        for item in told {
            guard let other = item.other, let span = lines ?? item.lines else { continue }
            var sessions = [editor.id]
            var otherSession: Session?
            if case .session(let id) = other, id != editor.id, let o = session(id) { sessions.append(id); otherSession = o }
            let where_ = "\(cleanPath) \(OverlapNotice.span(span))"
            let summary: String
            switch (other, otherSession) {
            case (_, let o?): summary = "\"\(editorName)\" and \"\(TugOfWar.clean(o.name))\" are both changing \(where_)"
            case (.user, _): summary = "\"\(editorName)\" is changing \(where_), where you have changes"
            default: summary = "\"\(editorName)\" is changing \(where_), next to another change"
            }
            if let i = overlapWarnings.firstIndex(where: { $0.key == item.key && $0.warning.sessions.first == editor.id && $0.warning.path == path }) {
                overlapWarnings[i].warning.date = date
                overlapWarnings[i].warning.lines = span
                overlapWarnings[i].warning.summary = summary
                continue
            }
            var edits = Set<UUID>()
            if let e = item.edit { edits.insert(e) }
            let warning = CoordinationWarning(id: UUID(), kind: .overlap, sessions: sessions, path: path, lines: span, date: date,
                                              escalated: false, summary: summary)
            var tools: Set<String> = [tool]
            if item.key.hasPrefix("tool:") { tools.insert(String(item.key.dropFirst(5))) }   // the other party's call
            overlapWarnings.append(OverlapWarningRecord(warning: warning, key: item.key, edits: edits, tools: tools, editorTool: tool))
            if let otherSession { showOverlapNotice("\"\(editorName)\" is editing \(where_) next to your change", to: otherSession, at: date) }
        }
        if overlapWarnings.count > Self.maxOverlapWarnings { overlapWarnings.removeFirst(overlapWarnings.count - Self.maxOverlapWarnings) }
        armWarningExpiry()
    }

    /// Appends the notice unless this session already got the same text within `overlapNoticeWindow`.
    private func showOverlapNotice(_ text: String, to session: Session, at date: Date) {
        overlapNoticeShown = overlapNoticeShown.filter { date.timeIntervalSince($0.value) < Self.overlapNoticeWindow }
        let key = OverlapNoticeKey(session: session.id, text: text)
        if overlapNoticeShown[key] != nil { return }
        overlapNoticeShown[key] = date
        session.transcript.appendNotice(kind: .warning, text: text)
    }

    private func pruneOverlapWarnings() {
        let t = now()
        guard overlapWarnings.contains(where: { t.timeIntervalSince($0.warning.date) > Self.warningLifetime }) else { return }
        overlapWarnings.removeAll { t.timeIntervalSince($0.warning.date) > Self.warningLifetime }
    }

    /// Called after the ledger of `path` changed. An applied edit of a warned tool call joins the warning; a warning
    /// whose edits are all kept, reverted or committed is resolved and goes.
    func refreshOverlapWarnings(_ path: String) {
        guard overlapWarnings.contains(where: { $0.warning.path == path }) else { return }
        let edits = ledger.files[path]?.edits ?? []
        let live = Set(edits.filter { $0.state == .live }.map(\.id))
        for i in overlapWarnings.indices where overlapWarnings[i].warning.path == path {
            for e in edits where e.state == .live {
                if let t = e.toolUseID, overlapWarnings[i].tools.contains(t) { overlapWarnings[i].edits.insert(e.id) }
            }
        }
        func resolved(_ r: OverlapWarningRecord) -> Bool { r.warning.path == path && !r.edits.isEmpty && r.edits.isDisjoint(with: live) }
        if overlapWarnings.contains(where: resolved) { overlapWarnings.removeAll(where: resolved) }
        pruneOverlapWarnings()
        armWarningExpiry()
    }

    // MARK: Tug notices

    /// The tug in both parties' chats (sessions only). `.warning` when it starts, `.error` when it escalates.
    func tugNotice(_ alert: TugAlert, kind: NoticeKind) {
        let w = tugWarning(alert)
        let text = kind == .error
            ? "\(w.summary). Alloy has not paused or blocked anything."
            : "\(w.summary)."
        for id in w.sessions { session(id)?.transcript.appendNotice(kind: kind, text: text) }
    }
}
