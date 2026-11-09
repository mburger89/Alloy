import AlloyTestSupport
import Foundation
import Testing
@testable import AlloyCore

private final class TugClock: @unchecked Sendable {
    var date = Date(timeIntervalSince1970: 1_800_000_000)
}

private final class TugTransports: @unchecked Sendable {
    private let lock = NSLock()
    private var all: [ScriptedTransport] = []
    var list: [ScriptedTransport] { lock.withLock { all } }
    var factory: TransportFactory {
        { [self] _ in
            let t = ScriptedTransport()
            lock.withLock { all.append(t) }
            return t
        }
    }
}

@MainActor @Suite(.timeLimit(.minutes(1))) final class TugOfWarTests {
    private var dirs: [URL] = []
    deinit { dirs.forEach { try? FileManager.default.removeItem(at: $0) } }

    static let base = (1...40).map { "line\($0)\n" }.joined()

    private func tempDir() -> URL {
        let u = FileManager.default.temporaryDirectory.appendingPathComponent("alloy-tug-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        dirs.append(u)
        return u
    }

    private struct Rig {
        let ws: Workspace
        let a: Session
        let b: Session
        let clock: TugClock
        let tr: TugTransports
    }

    private func rig() async -> Rig {
        let clock = TugClock(), tr = TugTransports()
        let ws = Workspace(projectRoot: tempDir(), appSupport: tempDir(), settings: AlloySettings(),
                           locate: { _ in URL(fileURLWithPath: "/fake/claude") }, makeTransport: tr.factory,
                           now: { clock.date })
        let a = await ws.newSession(name: "Ada")
        let b = await ws.newSession(name: "Bea")
        return Rig(ws: ws, a: a, b: b, clock: clock, tr: tr)
    }

    /// `author` rewrites `lines` to `tag` on top of the file's current text, `after` seconds from now.
    private func edit(_ r: Rig, _ author: Author, _ lines: [Int], _ tag: String, file: String = "f.txt", after: TimeInterval = 30) async {
        r.clock.date.addTimeInterval(after)
        var t = TextLines(r.ws.ledger.files[file]?.text.text ?? Self.base)
        for n in lines { t.lines[n - 1] = "\(tag)\(n)" }
        await r.ws.appendToLedger(file, saved: nil, baseline: Self.base, edits: [(author, t.text)])
        await r.ws.settle()
    }

    private func sentTexts(_ t: ScriptedTransport) async -> [String] {
        await t.sentAfterInitialize.compactMap {
            guard case .user(let content, _, _) = $0 else { return nil }
            return content.compactMap { if case .text(let s) = $0 { s } else { nil } }.joined()
        }
    }

    /// The CLI takes up the newest message sent to session `i`: it echoes the message's uuid.
    private func echo(_ r: Rig, _ i: Int) async {
        let t = r.tr.list[i]
        let uuids = await t.sentAfterInitialize.compactMap { m -> UUID? in if case .user(_, let uuid, _) = m { uuid } else { nil } }
        guard let u = uuids.last else { Issue.record("no message to echo"); return }
        await t.emit(.userEcho(text: "stop", imageCount: 0, uuid: u.uuidString, isReplay: true))
        await r.ws.settle()
        r.clock.date.addTimeInterval(1)
    }

    private func errorNotices(_ s: Session) -> Int {
        s.transcript.blocks.filter { if case .notice(_, .error, let t) = $0 { t.contains("has not paused") } else { false } }.count
    }

    private func stop(_ lines: String, other: String, path: String = "f.txt") -> String {
        "Message from Alloy itself (via Alloy): Lines \(lines) of \(path) are going back and forth between you and \"\(other)\". Leave them as they are now and move on with the rest of your task."
    }

    @Test func abaWithinTenMinutesSendsStopToLatest() async {
        let r = await rig()
        await edit(r, .session(r.a.id), [5, 6], "A")
        await edit(r, .session(r.b.id), [5, 6], "B")
        #expect(r.ws.tugAlerts.isEmpty)
        await edit(r, .session(r.a.id), [5, 6], "C")
        #expect(await sentTexts(r.tr.list[0]) == [stop("5\u{2013}6", other: "Bea")])
        #expect(await sentTexts(r.tr.list[1]).isEmpty)
        let alert = r.ws.tugAlerts.first
        #expect(r.ws.tugAlerts.count == 1)
        #expect(alert?.path == "f.txt" && alert?.lines == 5...6 && alert?.latest == .session(r.a.id))
        #expect(Set(alert?.parties ?? []) == [.session(r.a.id), .session(r.b.id)])
        #expect(alert?.escalated == false)
        // The row in A's chat reads "From Alloy".
        #expect(r.a.transcript.blocks.contains { if case .sessionMessage(_, .system, "Alloy", nil, _) = $0 { true } else { false } })
    }

    @Test func abaAfterTenMinutesDoesNot() async {
        let r = await rig()
        await edit(r, .session(r.a.id), [5], "A")
        await edit(r, .session(r.b.id), [5], "B", after: 360)
        await edit(r, .session(r.a.id), [5], "C", after: 360)   // the first A edit is 12 minutes old
        #expect(r.ws.tugAlerts.isEmpty)
        #expect(await sentTexts(r.tr.list[0]).isEmpty)
    }

    @Test func ignoredStopEscalatesOnce() async {
        let r = await rig()
        await edit(r, .session(r.a.id), [5], "A")
        await edit(r, .session(r.b.id), [5], "B")
        await edit(r, .session(r.a.id), [5], "C")
        #expect(r.ws.tugAlerts.first?.escalated == false)
        await echo(r, 0)   // the session has now taken the stop up
        await edit(r, .session(r.a.id), [5], "D")
        #expect(r.ws.tugAlerts.count == 1 && r.ws.tugAlerts.first?.escalated == true)
        #expect(errorNotices(r.a) == 1)
        await edit(r, .session(r.a.id), [5], "E")
        #expect(r.ws.tugAlerts.count == 1 && r.ws.tugAlerts.first?.escalated == true)
        #expect(errorNotices(r.a) == 1)
        // One stop message in total; nothing for B; nothing blocked.
        #expect(await sentTexts(r.tr.list[0]).count == 1)
        #expect(await sentTexts(r.tr.list[1]).isEmpty)
    }

    @Test func editsBeforeTheStopIsTakenUpDoNotEscalate() async {
        let r = await rig()
        await edit(r, .session(r.a.id), [5], "A")
        await edit(r, .session(r.b.id), [5], "B")
        await edit(r, .session(r.a.id), [5], "C")
        // A response already under way makes more edits before the queued stop can reach the model.
        await edit(r, .session(r.a.id), [5], "D")
        await edit(r, .session(r.a.id), [5], "E")
        #expect(r.ws.tugAlerts.count == 1 && r.ws.tugAlerts.first?.escalated == false)
        #expect(errorNotices(r.a) == 0)
        // Once it is taken up, a further edit of those lines is ignoring it.
        await echo(r, 0)
        await edit(r, .session(r.a.id), [5], "F")
        #expect(r.ws.tugAlerts.first?.escalated == true)
        #expect(errorNotices(r.a) == 1)
    }

    @Test func obeyingSessionNextToTheRangeDoesNotEscalate() async {
        let r = await rig()
        await edit(r, .session(r.a.id), [5], "A")
        await edit(r, .session(r.b.id), [5], "B")
        await edit(r, .session(r.a.id), [5], "C")
        await echo(r, 0)
        await edit(r, .session(r.a.id), [7], "D")   // two lines below: inside the margin, outside the told lines
        #expect(r.ws.tugAlerts.count == 1 && r.ws.tugAlerts.first?.escalated == false)
        #expect(errorNotices(r.a) == 0)
    }

    @Test func noStopIsSentWhenSharingIsOffAndSoNothingEscalates() async {
        let r = await rig()
        var off = AlloySettings(); off.shareKnowledge = false
        try? r.ws.updateSettings(off)
        await edit(r, .session(r.a.id), [5], "A")
        await edit(r, .session(r.b.id), [5], "B")
        await edit(r, .session(r.a.id), [5], "C")
        #expect(r.ws.tugAlerts.count == 1)                       // the user still sees it
        #expect(await sentTexts(r.tr.list[0]).isEmpty)
        await edit(r, .session(r.a.id), [5], "D")
        #expect(r.ws.tugAlerts.first?.escalated == false)
        #expect(errorNotices(r.a) == 0)
    }

    @Test func userAsLatestEditorOnlyAlerts() async {
        let r = await rig()
        await edit(r, .user, [5], "U")
        await edit(r, .session(r.b.id), [5], "B")
        await edit(r, .user, [5], "V")
        #expect(r.ws.tugAlerts.count == 1)
        #expect(r.ws.tugAlerts.first?.latest == .user)
        #expect(Set(r.ws.tugAlerts.first?.parties ?? []) == [.user, .session(r.b.id)])
        #expect(await sentTexts(r.tr.list[0]).isEmpty)
        #expect(await sentTexts(r.tr.list[1]).isEmpty)
        // More user typing never escalates, since nobody was told.
        await edit(r, .user, [5], "W")
        #expect(r.ws.tugAlerts.first?.escalated == false)
    }

    @Test func differentLinesAreNotATug() async {
        let r = await rig()
        await edit(r, .session(r.a.id), [5], "A")
        await edit(r, .session(r.b.id), [20], "B")
        await edit(r, .session(r.a.id), [5], "C")
        await edit(r, .session(r.b.id), [20], "D")
        #expect(r.ws.tugAlerts.isEmpty)
        #expect(await sentTexts(r.tr.list[0]).isEmpty)
        #expect(await sentTexts(r.tr.list[1]).isEmpty)
    }

    @Test func adjacentLinesWithinMarginCount() async {
        let r = await rig()
        await edit(r, .session(r.a.id), [5], "A")
        await edit(r, .session(r.b.id), [7], "B")
        await edit(r, .session(r.a.id), [8], "C")
        #expect(r.ws.tugAlerts.count == 1)
    }

    @Test func outsideEditsAreNotAParty() async {
        let r = await rig()
        await edit(r, .session(r.a.id), [5], "A")
        await edit(r, .outside, [5], "O")
        await edit(r, .session(r.a.id), [5], "C")
        #expect(r.ws.tugAlerts.isEmpty)
    }

    @Test func keptEditsStillCountAsHistoryAndKeepingClearsTheAlert() async throws {
        let r = await rig()
        await edit(r, .session(r.a.id), [5], "A")
        let first = try #require(r.ws.ledger.files["f.txt"]?.edits.first?.id)
        r.ws.keep(edit: first, path: "f.txt")
        await edit(r, .session(r.b.id), [5], "B")
        await edit(r, .session(r.a.id), [5], "C")
        #expect(r.ws.tugAlerts.count == 1)
        r.ws.keepAllEdits(path: "f.txt")
        #expect(r.ws.tugAlerts.isEmpty)
    }

    @Test func alertClearsTenMinutesAfterLastActivity() async {
        let r = await rig()
        await edit(r, .session(r.a.id), [5], "A")
        await edit(r, .session(r.b.id), [5], "B")
        await edit(r, .session(r.a.id), [5], "C")
        r.clock.date.addTimeInterval(500)
        r.ws.pruneTugAlerts()
        #expect(r.ws.tugAlerts.count == 1)
        r.clock.date.addTimeInterval(120)
        r.ws.pruneTugAlerts()
        #expect(r.ws.tugAlerts.isEmpty)
    }

    @Test func alertListIsCappedAtFifty() async {
        let r = await rig()
        for i in 0..<52 {
            let f = "f\(i).txt"
            await edit(r, .session(r.a.id), [5], "A", file: f, after: 1)
            await edit(r, .session(r.b.id), [5], "B", file: f, after: 1)
            await edit(r, .session(r.a.id), [5], "C", file: f, after: 1)
        }
        #expect(r.ws.tugAlerts.count == 50)
        #expect(r.ws.tugAlerts.last?.path == "f51.txt")
    }

    /// `author` replaces the whole file text.
    private func rewrite(_ r: Rig, _ author: Author, _ text: String, file: String = "f.txt", after: TimeInterval = 30) async {
        r.clock.date.addTimeInterval(after)
        await r.ws.appendToLedger(file, saved: nil, baseline: Self.base, edits: [(author, text)])
        await r.ws.settle()
    }

    private func current(_ r: Rig, file: String = "f.txt") -> [String] { r.ws.ledger.files[file]?.text.lines ?? [] }

    @Test func controlCharactersCannotForgeQuotesInTheMessage() async {
        let r = await rig()
        r.b.name = "Be\u{1}a \"x\" \u{7}"
        let file = "a\u{1}b.txt"
        await edit(r, .session(r.a.id), [5], "A", file: file)
        await edit(r, .session(r.b.id), [5], "B", file: file)
        await edit(r, .session(r.a.id), [5], "C", file: file)
        let got = await sentTexts(r.tr.list[0])
        #expect(got.count == 1)
        let text = got.first ?? ""
        #expect(text.filter { $0 == "\"" }.count == 2)
        #expect(!text.unicodeScalars.contains { $0.value < 0x20 })
        #expect(text.contains("between you and \"Bea 'x'\"."))
    }

    @Test func staleLinesShiftWhenLinesAreInsertedAbove() async {
        let r = await rig()
        await edit(r, .session(r.a.id), [5], "A")
        await edit(r, .session(r.b.id), [5], "B")
        let inserted = (1...100).map { "ins\($0)" } + current(r)
        await rewrite(r, .outside, inserted.map { $0 + "\n" }.joined())
        #expect(r.ws.tugAlerts.isEmpty)
        await edit(r, .session(r.a.id), [105], "C")
        #expect(r.ws.tugAlerts.count == 1)
        #expect(r.ws.tugAlerts.first?.lines == 105...105)
        #expect(await sentTexts(r.tr.list[0]).count == 1)
    }

    @Test func linesThatMoveIntoPlaceAfterADeleteAreNotPaired() async {
        let r = await rig()
        await edit(r, .session(r.a.id), [10], "A")             // A at 10
        await rewrite(r, .outside, current(r).dropFirst(5).map { $0 + "\n" }.joined())   // lines 1-5 deleted: A's line is now 5
        await edit(r, .session(r.b.id), [10], "B")             // B at 10 (was 15)
        await edit(r, .session(r.a.id), [10], "C")             // A again, on B's line, 5 lines from its own
        #expect(r.ws.tugAlerts.isEmpty)
        #expect(await sentTexts(r.tr.list[0]).isEmpty)
    }

    @Test func tugStraddlingABucketBoundaryStaysOneAlertAndOneMessage() async {
        let r = await rig()
        await edit(r, .session(r.a.id), [19], "A")
        await edit(r, .session(r.b.id), [19], "B")
        await edit(r, .session(r.a.id), [19], "C")
        await edit(r, .session(r.a.id), [21], "D")             // the hull's start moves into the next 20-line bucket
        #expect(r.ws.tugAlerts.count == 1)
        #expect(await sentTexts(r.tr.list[0]).count == 1)
    }

    @Test func keepingTheNewestEditClearsTheAlertButNotTheStopMemory() async throws {
        let r = await rig()
        await edit(r, .session(r.a.id), [5], "A")
        await edit(r, .session(r.b.id), [5], "B")
        await edit(r, .session(r.a.id), [5], "C")
        let newest = try #require(r.ws.ledger.files["f.txt"]?.edits.last?.id)
        r.ws.keep(edit: newest, path: "f.txt")
        #expect(r.ws.tugAlerts.isEmpty)                         // other involved edits are still live
        await edit(r, .session(r.a.id), [5], "D")
        #expect(await sentTexts(r.tr.list[0]).count == 1)       // no second stop
        #expect(r.ws.tugAlerts.count == 1 && r.ws.tugAlerts.first?.escalated == false)   // a warning again, not red
    }

    @Test func theOtherPartyGetsItsOwnStopWhenItEditsNext() async {
        let r = await rig()
        await edit(r, .session(r.a.id), [5], "A")
        await edit(r, .session(r.b.id), [5], "B")
        await edit(r, .session(r.a.id), [5], "C")
        await edit(r, .session(r.b.id), [5], "D")               // B is now the latest editor
        #expect(await sentTexts(r.tr.list[0]).count == 1)
        #expect(await sentTexts(r.tr.list[1]) == [stop("5\u{2013}5", other: "Ada")])
        #expect(r.ws.tugAlerts.count == 1 && r.ws.tugAlerts.first?.latest == .session(r.b.id))
        #expect(r.ws.tugAlerts.first?.escalated == false)
    }

    @Test func hullCoversOnlyTheRunsThatOverlapTheOtherParty() async {
        let r = await rig()
        await edit(r, .session(r.a.id), [5], "A")
        await edit(r, .session(r.b.id), [5], "B")
        await edit(r, .session(r.a.id), [5, 30], "C")
        #expect(r.ws.tugAlerts.first?.lines == 5...5)
        #expect(await sentTexts(r.tr.list[0]) == [stop("5\u{2013}5", other: "Bea")])
    }

    @Test func insertAboveATugInProgressKeepsOneAlertAndOneMessage() async {
        let r = await rig()
        await edit(r, .session(r.a.id), [5], "A")
        await edit(r, .session(r.b.id), [5], "B")
        await edit(r, .session(r.a.id), [5], "C")
        await echo(r, 0)
        await rewrite(r, .outside, ((1...100).map { "ins\($0)" } + current(r)).map { $0 + "\n" }.joined())
        await edit(r, .session(r.a.id), [105], "D")
        #expect(r.ws.tugAlerts.count == 1)
        #expect(r.ws.tugAlerts.first?.lines == 5...105 || r.ws.tugAlerts.first?.lines == 105...105)
        #expect(r.ws.tugAlerts.first?.escalated == true)
        #expect(await sentTexts(r.tr.list[0]).count == 1)
    }

    // MARK: remap

    private func hunk(_ os: Int, _ ol: Int, _ ns: Int, _ nl: Int, _ lines: [String]) -> PatchHunk {
        PatchHunk(oldStart: os, oldLines: ol, newStart: ns, newLines: nl, lines: lines)
    }

    @Test func remapPureInsertBelowATrackedLineLeavesItInPlace() {
        // Two lines inserted after line 5 (unified-diff convention for oldLines == 0).
        let h = [hunk(5, 0, 6, 2, ["+a", "+b"])]
        #expect(TugOfWar.remap(4, h) == 4)
        #expect(TugOfWar.remap(5, h) == 5)
        #expect(TugOfWar.remap(6, h) == 8)
        // At the top of the file.
        #expect(TugOfWar.remap(1, [hunk(0, 0, 1, 2, ["+a", "+b"])]) == 3)
    }

    @Test func remapPureDelete() {
        let h = [hunk(5, 2, 4, 0, ["-x", "-y"])]
        #expect(TugOfWar.remap(4, h) == 4)
        #expect(TugOfWar.remap(5, h) == 5)   // a deleted line lands where its text was
        #expect(TugOfWar.remap(7, h) == 5)
    }

    @Test func remapReplace() {
        let h = [hunk(5, 1, 5, 3, ["-x", "+y", "+z", "+w"])]
        #expect(TugOfWar.remap(4, h) == 4)
        #expect(TugOfWar.remap(5, h) == 5)
        #expect(TugOfWar.remap(6, h) == 8)
    }

    @Test func remapTwoHunksInOneEdit() {
        // Two lines inserted after line 3, then line 10 deleted (which sits at 12 after the insert).
        let h = [hunk(3, 0, 4, 2, ["+a", "+b"]), hunk(10, 1, 11, 0, ["-x"])]
        #expect(TugOfWar.remap(2, h) == 2)
        #expect(TugOfWar.remap(3, h) == 3)
        #expect(TugOfWar.remap(4, h) == 6)
        #expect(TugOfWar.remap(9, h) == 11)
        #expect(TugOfWar.remap(11, h) == 12)
    }
}
