@testable import AlloyCore
@testable import AlloyKit
import AlloyTestSupport
import Foundation
import MetalUI
import MetalUITesting
import Testing

private final class WarnClock: @unchecked Sendable {
    var date = Date(timeIntervalSince1970: 1_800_000_000)
}

@MainActor
private final class WarnRig {
    let workspace: Workspace
    let root: URL
    let clock: WarnClock
    let manual: ManualClock
    let bag: TransportBag
    let a: Session
    let b: Session
    static let base = (1...30).map { "line\($0)\n" }.joined()

    static func make() async -> WarnRig {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("alloy-warn-\(UUID().uuidString)").resolvingSymlinksInPath()
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try? base.write(to: root.appendingPathComponent("f.txt"), atomically: true, encoding: .utf8)
        let clock = WarnClock(), bag = TransportBag(), manual = ManualClock()
        let ws = Workspace(projectRoot: root, appSupport: root.appendingPathComponent("support"), settings: AlloySettings(),
                           locate: { _ in URL(fileURLWithPath: "/fake/claude") }, makeTransport: { _ in bag.make() },
                           now: { clock.date }, autosaveClock: manual)
        let a = await ws.newSession(name: "Ada"), b = await ws.newSession(name: "Bea")
        return WarnRig(workspace: ws, root: root, clock: clock, manual: manual, bag: bag, a: a, b: b)
    }

    private init(workspace: Workspace, root: URL, clock: WarnClock, manual: ManualClock, bag: TransportBag, a: Session, b: Session) {
        self.workspace = workspace; self.root = root; self.a = a; self.b = b; self.clock = clock
        self.manual = manual; self.bag = bag
    }
    deinit { try? FileManager.default.removeItem(at: root) }

    /// The CLI takes up the newest message sent to session `i` (the stop message): it echoes the message's uuid.
    func echoStop(_ i: Int) async {
        let uuids = await bag[i].sentAfterInitialize.compactMap { m -> UUID? in if case .user(_, let uuid, _) = m { uuid } else { nil } }
        guard let u = uuids.last else { Issue.record("no message to echo"); return }
        await bag[i].emit(.userEcho(text: "stop", imageCount: 0, uuid: u.uuidString, isReplay: true))
        await workspace.settle()
        advance(1)
    }

    /// Polls on the main actor until `condition` holds (up to 5 s). `emit` only queues an event on the session's
    /// stream; the workspace's consumer task handles it on a later main-actor turn, which `settle()` does not wait for.
    func until(_ condition: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(5)
        while !condition() {
            if ContinuousClock.now > deadline { return false }
            try? await Task.sleep(for: .milliseconds(2))
        }
        return true
    }

    func advance(_ seconds: TimeInterval) { clock.date.addTimeInterval(seconds); manual.advance(by: seconds) }

    /// Lets the expiry sleeper wake and run after `advance`.
    func wake() async { await workspace.warningSleeper?.value }

    /// `text` becomes the file's text, as `author`'s live edit.
    func applied(_ author: Author, _ lines: [Int: String]) async {
        var l = TextLines(workspace.ledger.files["f.txt"]?.text.text ?? Self.base)
        for (n, s) in lines { l.lines[n - 1] = s }
        await workspace.appendToLedger("f.txt", saved: nil, baseline: Self.base, edits: [(author, l.text)])
        await workspace.settle()
    }

    /// The session's PreToolUse for an Edit of one line.
    @discardableResult
    func hook(_ s: Session, id: String, line: Int) -> HookReply {
        let input: JSONValue = .object(["file_path": .string(root.appendingPathComponent("f.txt").path),
                                        "old_string": .string("line\(line)\n"), "new_string": .string("changed\n")])
        let req = HookRequest(event: .preToolUse, toolName: "Edit", toolUseID: id, toolInput: input, cliSessionID: "cli")
        return workspace.handleHook(req, caller: MCPCaller(sessionID: s.id))
    }

    /// Bea changed line 10; Ada is about to edit line 11.
    func overlap() async {
        await applied(.session(b.id), [10: "BBB"])
        hook(a, id: "ta", line: 11)
    }

    func window(width: Float = 1200, dark: Bool = false) throws -> TestWindow {
        let ws = workspace
        let w = try TestWindow(size: Size(width: Pixels(width), height: Pixels(800)), colorScheme: dark ? .dark : .light) { rootView(workspace: ws) }
        w.tick(); w.tick()
        return w
    }

    func notices(_ s: Session) -> [String] {
        s.transcript.blocks.compactMap { if case .notice(_, .warning, let t) = $0 { t } else { nil } }
    }
}

@MainActor
private func noticeText(_ e: TestElement, _ w: TestWindow) -> String {
    ([e.label, e.value].compactMap { $0 } + descendants(of: e, in: w).compactMap { $0.value ?? $0.label }).joined(separator: " ")
}

@MainActor
@Suite(.timeLimit(.minutes(2))) struct CoordinationWarningsTests {
    @Test func overlapMarksBothSessionsAndTheFile() async throws {
        let r = await WarnRig.make()
        await r.overlap()
        let warnings = r.workspace.coordinationWarnings
        #expect(warnings.count == 1)
        #expect(warnings.first?.kind == .overlap && Set(warnings.first?.sessions ?? []) == [r.a.id, r.b.id])
        #expect(warnings.first?.path == "f.txt" && warnings.first?.escalated == false)
        let w = try r.window()
        try await w.runUntil { (try? w.element(identifier: "session-warning-\(r.a.id.uuidString)")) != nil }
        let ma = try w.element(identifier: "session-warning-\(r.a.id.uuidString)")
        let mb = try w.element(identifier: "session-warning-\(r.b.id.uuidString)")
        let mf = try w.element(identifier: "changed-file-warning-f.txt")
        for m in [ma, mb, mf] {
            let hint = try #require(m.hint)
            #expect(!hint.isEmpty && !hint.contains("\n") && hint.contains("f.txt"), "\(hint)")
        }
        // Both chats carry the warning: Ada's is the hook reply's, Bea's names the editor.
        #expect(r.notices(r.a).count == 1)
        let toB = r.notices(r.b)
        #expect(toB == ["\"Ada\" is editing f.txt line 11 next to your change"], "\(toB)")
    }

    @Test func otherSessionGetsNoDuplicateAndTheUserGetsNoNotice() async throws {
        let r = await WarnRig.make()
        await r.overlap()
        r.hook(r.a, id: "ta2", line: 11)   // told once: no second warning, no second notice
        #expect(r.workspace.coordinationWarnings.count == 1)
        #expect(r.notices(r.b).count == 1)
    }

    @Test func markersFitTheRowAndDoNotTouchTheMenu() async throws {
        let r = await WarnRig.make()
        await r.overlap()
        // 760 is the narrowest window: the sidebar is at its 200 pt minimum.
        let w = try r.window(width: 760)
        try await w.runUntil { (try? w.element(identifier: "session-warning-\(r.a.id.uuidString)")) != nil }
        for s in [r.a, r.b] {
            let row = try w.element(identifier: "session-row-\(s.id.uuidString)").frame
            let mark = try w.element(identifier: "session-warning-\(s.id.uuidString)").frame
            let menu = try w.element(identifier: "session-menu-\(s.id.uuidString)").frame
            #expect(row.size.height.value <= 62.5 && row.size.width.value < 210, "the sidebar is at its 200 pt minimum")
            #expect(mark.origin.x.value >= row.origin.x.value && mark.origin.x.value + mark.size.width.value <= row.origin.x.value + row.size.width.value)
            #expect(mark.origin.y.value >= row.origin.y.value && mark.origin.y.value + mark.size.height.value <= row.origin.y.value + row.size.height.value)
            #expect(mark.origin.x.value + mark.size.width.value <= menu.origin.x.value, "the marker ends before the menu button")
            #expect(mark.size.width.value < 40)
        }
    }

    @Test func noticeShowsForOtherSessionAndSelectsIt() async throws {
        let r = await WarnRig.make()
        #expect(r.workspace.selectedSessionID == r.a.id)
        await r.overlap()
        let w = try r.window()
        try await w.runUntil { (try? w.element(identifier: "coordination-notice")) != nil }
        let notice = try w.element(identifier: "coordination-notice")
        let text = noticeText(notice, w)
        #expect(text.contains("f.txt"), "\(text)")
        try w.click(notice)
        try await w.runUntil { r.workspace.selectedSessionID == r.b.id }
        // Followed: it goes away, and the other session's notice does not replace it.
        try await w.runUntil { (try? w.element(identifier: "coordination-notice")) == nil }
    }

    @Test func noticeCanBeDismissedAndIsAbsentWhenOnlyTheSelectedSessionIsInvolved() async throws {
        let r = await WarnRig.make()
        await r.overlap()
        let w = try r.window()
        try await w.runUntil { (try? w.element(identifier: "coordination-notice")) != nil }
        try w.click(w.element(identifier: "coordination-notice-dismiss"))
        try await w.runUntil { (try? w.element(identifier: "coordination-notice")) == nil }
        #expect(r.workspace.selectedSessionID == r.a.id)
        // The markers stay: dismissing hides the strip, it resolves nothing.
        #expect((try? w.element(identifier: "session-warning-\(r.b.id.uuidString)")) != nil)
        // A warning that involves only the selected session needs no strip.
        let solo = await WarnRig.make()
        solo.workspace.overlapWarnings.append(OverlapWarningRecord(
            warning: CoordinationWarning(id: UUID(), kind: .overlap, sessions: [solo.a.id], path: "f.txt", lines: 3...4,
                                         date: solo.clock.date, escalated: false, summary: "x"), key: "k", edits: [], tools: []))
        let w2 = try solo.window()
        for _ in 0..<5 { w2.tick() }
        #expect((try? w2.element(identifier: "coordination-notice")) == nil)
        #expect((try? w2.element(identifier: "session-warning-\(solo.a.id.uuidString)")) != nil)
    }

    @Test func onlyTheNewestWarningIsShown() async throws {
        let r = await WarnRig.make()
        await r.overlap()
        r.advance(30)
        await r.applied(.session(r.b.id), [20: "BBB"])
        r.hook(r.a, id: "ta3", line: 21)
        #expect(r.workspace.coordinationWarnings.count == 2)
        let w = try r.window()
        try await w.runUntil { (try? w.element(identifier: "coordination-notice")) != nil }
        let all = try w.elements(where: { $0.identifier == "coordination-notice" })
        #expect(all.count == 1)
        let text = noticeText(all[0], w)
        #expect(text.contains("21") && !text.contains("11"), "\(text)")
    }

    @Test func escalationIsTheOnlyRed() async throws {
        let r = await WarnRig.make()
        await r.overlap()
        let overlap = try #require(r.workspace.coordinationWarnings.first)
        #expect(CoordinationStyle.isRed(overlap) == false)
        // A tug of war: A, B, A is a warning; A again after the stop is the escalation.
        let t = await WarnRig.make()
        await t.applied(.session(t.a.id), [5: "A"]); t.advance(30)
        await t.applied(.session(t.b.id), [5: "B"]); t.advance(30)
        await t.applied(.session(t.a.id), [5: "C"]); t.advance(30)
        let tug = try #require(t.workspace.coordinationWarnings.first { $0.kind == .tug })
        #expect(tug.escalated == false && CoordinationStyle.isRed(tug) == false)
        #expect(CoordinationStyle.colors(for: tug).tint == Color.warningTint)
        // Both chats show the tug, in the warning style.
        #expect(t.notices(t.a).count == 1 && t.notices(t.b).count == 1)
        await t.echoStop(0)
        await t.applied(.session(t.a.id), [5: "D"])
        let escalated = try #require(t.workspace.coordinationWarnings.first { $0.kind == .tug })
        #expect(escalated.escalated && CoordinationStyle.isRed(escalated))
        #expect(CoordinationStyle.colors(for: escalated).ink == Color.errorInk && CoordinationStyle.colors(for: escalated).tint == Color.errorTint)
        // The only red notice in a chat is the escalation.
        func errors(_ s: Session) -> Int { s.transcript.blocks.filter { if case .notice(_, .error, _) = $0 { true } else { false } }.count }
        #expect(errors(t.a) == 1 && errors(t.b) == 1)
        #expect(errors(r.a) == 0 && errors(r.b) == 0)
        // And on screen the escalated marker paints the error tint, the plain tug the warning tint.
        let w = try t.window()
        try await w.runUntil { (try? w.element(identifier: "session-warning-\(t.a.id.uuidString)")) != nil }
        let frame = try w.element(identifier: "session-warning-\(t.a.id.uuidString)").frame
        let res = try resolvedInWindow([.errorTint, .warningTint], dark: false)
        func has(_ c: Color.Resolved) -> Bool {
            w.scene.rects.contains { r in
                let b = r.bounds
                guard b.origin.x < frame.origin.x.value + frame.size.width.value, b.origin.x + b.size.width > frame.origin.x.value,
                      b.origin.y < frame.origin.y.value + frame.size.height.value, b.origin.y + b.size.height > frame.origin.y.value
                else { return false }
                let h = Hsla(h: r.background.h, s: r.background.s, l: r.background.l, a: r.background.a).toRgba()
                return abs(h.r - c.red) < 0.01 && abs(h.g - c.green) < 0.01 && abs(h.b - c.blue) < 0.01
            }
        }
        #expect(has(res[0]) && !has(res[1]))
    }

    @Test func markersClearOnKeep() async throws {
        let r = await WarnRig.make()
        await r.overlap()
        #expect(r.workspace.coordinationWarnings.count == 1)
        let beas = try #require(r.workspace.ledger.files["f.txt"]?.edits.first { $0.author == .session(r.b.id) })
        r.workspace.keep(edit: beas.id, path: "f.txt")
        #expect(r.workspace.coordinationWarnings.isEmpty)
        let w = try r.window()
        for _ in 0..<5 { w.tick() }
        #expect((try? w.element(identifier: "session-warning-\(r.a.id.uuidString)")) == nil)
        #expect((try? w.element(identifier: "changed-file-warning-f.txt")) == nil)
        #expect((try? w.element(identifier: "coordination-notice")) == nil)
    }

    @Test func markersClearOnRevertAndCommit() async throws {
        let r = await WarnRig.make()
        await r.overlap()
        let beas = try #require(r.workspace.ledger.files["f.txt"]?.edits.first { $0.author == .session(r.b.id) })
        // The session's write reached the disk, as it would have.
        try r.workspace.ledger.files["f.txt"]!.text.text.write(to: r.root.appendingPathComponent("f.txt"), atomically: true, encoding: .utf8)
        let outcome = await r.workspace.revert(edit: beas.id, path: "f.txt")
        if case .reverted = outcome {} else { Issue.record("revert: \(outcome)") }
        #expect(r.workspace.coordinationWarnings.isEmpty)
        let c = await WarnRig.make()
        await c.overlap()
        c.workspace.keepAllEdits(path: "f.txt")
        #expect(c.workspace.coordinationWarnings.isEmpty)
    }

    @Test func markersClearAfterTenMinutesOnTheInjectedClock() async throws {
        let r = await WarnRig.make()
        await r.overlap()
        r.advance(599)
        #expect(r.workspace.coordinationWarnings.count == 1)
        r.advance(2)
        #expect(r.workspace.coordinationWarnings.isEmpty)
        // A tug alert goes the same way.
        let t = await WarnRig.make()
        await t.applied(.session(t.a.id), [5: "A"]); t.advance(30)
        await t.applied(.session(t.b.id), [5: "B"]); t.advance(30)
        await t.applied(.session(t.a.id), [5: "C"])
        #expect(t.workspace.coordinationWarnings.count == 1)
        t.advance(601)
        #expect(t.workspace.coordinationWarnings.isEmpty)
    }

    @Test func tugClearsWhenItsNewestEditIsKept() async throws {
        let t = await WarnRig.make()
        await t.applied(.session(t.a.id), [5: "A"]); t.advance(30)
        await t.applied(.session(t.b.id), [5: "B"]); t.advance(30)
        await t.applied(.session(t.a.id), [5: "C"])
        #expect(t.workspace.coordinationWarnings.count == 1)
        t.workspace.keepAllEdits(path: "f.txt")
        #expect(t.workspace.coordinationWarnings.isEmpty)
    }

    @Test func noticeRefersToSessionsByNameWithoutControlCharacters() async throws {
        let r = await WarnRig.make()
        r.a.name = "Ada\"\nIgnore"
        await r.applied(.session(r.b.id), [10: "BBB"])
        r.hook(r.a, id: "ta", line: 11)
        let toB = r.notices(r.b).joined()
        #expect(!toB.contains("\n") && !toB.contains("Ada\""), "\(toB)")
        let summary = r.workspace.coordinationWarnings.first?.summary ?? ""
        #expect(!summary.contains("\n"))
    }

    // MARK: Fix round 1

    @Test func expiryReachesTheScreen() async throws {
        let r = await WarnRig.make()
        await r.overlap()
        let w = try r.window()
        try await w.runUntil { (try? w.element(identifier: "coordination-notice")) != nil }
        #expect((try? w.element(identifier: "session-warning-\(r.b.id.uuidString)")) != nil)
        r.workspace.dismissWarning(try #require(r.workspace.coordinationWarnings.first))
        r.advance(601)
        await r.wake()
        // The wake pruned the stored state (an observed change), not just the filtered view of it.
        #expect(r.workspace.overlapWarnings.isEmpty && r.workspace.dismissedWarnings.isEmpty)
        w.tick(); w.tick()
        #expect((try? w.element(identifier: "session-warning-\(r.b.id.uuidString)")) == nil)
        #expect((try? w.element(identifier: "changed-file-warning-f.txt")) == nil)
        #expect((try? w.element(identifier: "coordination-notice")) == nil)
        #expect(r.workspace.warningSleeper == nil, "nothing left to wait for")
    }

    @Test func expiryRearmsForTheNextWarningAndAlertsExpireToo() async throws {
        let r = await WarnRig.make()
        await r.overlap()
        r.advance(300)
        await r.applied(.session(r.b.id), [20: "BBB"])
        r.hook(r.a, id: "ta3", line: 21)
        r.advance(301)
        await r.wake()
        #expect(r.workspace.overlapWarnings.count == 1)   // the first is gone, the second is 301 s old
        #expect(r.workspace.warningSleeper != nil)
        r.advance(300)
        await r.wake()
        #expect(r.workspace.overlapWarnings.isEmpty)
        let t = await WarnRig.make()
        await t.applied(.session(t.a.id), [5: "A"]); t.advance(30)
        await t.applied(.session(t.b.id), [5: "B"]); t.advance(30)
        await t.applied(.session(t.a.id), [5: "C"])
        t.advance(601)
        await t.wake()
        #expect(t.workspace.tugAlerts.isEmpty)
    }

    @Test func theExpirySleeperNeitherHangsSettleNorSurvivesStopAll() async throws {
        let r = await WarnRig.make()
        await r.overlap()
        #expect(r.workspace.warningSleeper != nil)
        await r.workspace.settle()   // returns although the sleeper is still waiting
        await r.workspace.stopAll()
        #expect(r.workspace.warningSleeper == nil)
        #expect(r.manual.pendingSleepers == 0)
    }

    @Test func aDismissedTugComesBackWhenItEscalates() async throws {
        let t = await WarnRig.make()
        await t.applied(.session(t.a.id), [5: "A"]); t.advance(30)
        await t.applied(.session(t.b.id), [5: "B"]); t.advance(30)
        await t.applied(.session(t.a.id), [5: "C"]); t.advance(30)
        let plain = try #require(t.workspace.coordinationWarnings.first)
        #expect(t.workspace.noticeWarning(selected: t.a.id)?.id == plain.id)
        t.workspace.dismissWarning(plain)
        #expect(t.workspace.noticeWarning(selected: t.a.id) == nil)
        await t.echoStop(0)
        await t.applied(.session(t.a.id), [5: "D"])
        let escalated = try #require(t.workspace.noticeWarning(selected: t.a.id))
        #expect(escalated.escalated && escalated.id == plain.id)
        // Dismissing the escalation hides it for good.
        t.workspace.dismissWarning(escalated)
        #expect(t.workspace.noticeWarning(selected: t.a.id) == nil)
    }

    @Test func theStripPrefersAnEscalationOverANewerPlainWarning() async throws {
        let t = await WarnRig.make()
        await t.applied(.session(t.a.id), [5: "A"]); t.advance(30)
        await t.applied(.session(t.b.id), [5: "B"]); t.advance(30)
        await t.applied(.session(t.a.id), [5: "C"]); t.advance(30)
        await t.echoStop(0)
        await t.applied(.session(t.a.id), [5: "D"]); t.advance(30)
        await t.applied(.session(t.b.id), [20: "BBB"])
        t.hook(t.a, id: "ta9", line: 21)
        let all = t.workspace.coordinationWarnings
        #expect(all.count == 2 && all.last?.kind == .overlap)
        #expect(t.workspace.noticeWarning(selected: t.a.id)?.escalated == true)
        let w = try t.window()
        try await w.runUntil { (try? w.element(identifier: "coordination-notice")) != nil }
        #expect(noticeText(try w.element(identifier: "coordination-notice"), w).contains("back and forth"))
    }

    @Test func aDeniedProposalClearsItsWarning() async throws {
        let r = await WarnRig.make()
        await r.overlap()
        #expect(r.workspace.coordinationWarnings.count == 1)
        await r.bag[0].emit(.toolResult(ToolResultMessage(toolUseID: "ta", isError: true, text: "denied",
                                                          result: .none)))
        // The result reaches the workspace through the session's stream; wait for its effect.
        #expect(await r.until { r.workspace.coordinationWarnings.isEmpty })
        // A different call's failure leaves another warning alone.
        let o = await WarnRig.make()
        await o.overlap()
        await o.bag[0].emit(.toolResult(ToolResultMessage(toolUseID: "other", isError: true, text: "x", result: .none)))
        // Nothing observable changes for "other", so give the stream a bounded stretch to deliver it, then check.
        try await Task.sleep(for: .milliseconds(100))
        await o.workspace.settle()
        #expect(o.workspace.coordinationWarnings.count == 1)
    }

    @Test func theOtherSessionsDeniedProposalClearsTheWarning() async throws {
        let r = await WarnRig.make()
        await r.applied(.outside, [25: "outside"])   // Alloy now holds the file
        r.hook(r.b, id: "tb", line: 10)      // Bea proposes; nothing is applied
        r.hook(r.a, id: "ta", line: 11)      // Ada is told about it
        #expect(r.workspace.coordinationWarnings.count == 1)
        await r.bag[1].emit(.toolResult(ToolResultMessage(toolUseID: "tb", isError: true, text: "denied", result: .none)))
        #expect(await r.until { r.workspace.coordinationWarnings.isEmpty })
        // If Ada's own edit went through, the warning stays: there is still a live edit beside the lines.
        let o = await WarnRig.make()
        await o.applied(.outside, [25: "outside"])
        o.hook(o.b, id: "tb", line: 10)
        o.hook(o.a, id: "ta", line: 11)
        let hunk = PatchHunk(oldStart: 11, oldLines: 1, newStart: 11, newLines: 1, lines: ["-line11", "+changed"])
        await o.bag[0].emit(.toolResult(ToolResultMessage(
            toolUseID: "ta", isError: false, text: "ok",
            result: .edit(filePath: o.root.appendingPathComponent("f.txt").path, originalFile: try #require(o.workspace.ledger.files["f.txt"]).currentText, hunks: [hunk]))))
        await o.workspace.settle()
        await o.bag[1].emit(.toolResult(ToolResultMessage(toolUseID: "tb", isError: true, text: "denied", result: .none)))
        await o.workspace.settle()
        #expect(o.workspace.coordinationWarnings.count == 1)
    }

    @Test func aSuccessfulCallKeepsTheWarningUntilTheEditorsEditIsKept() async throws {
        let r = await WarnRig.make()
        await r.overlap()
        let before = try #require(r.workspace.ledger.files["f.txt"]).currentText
        let hunk = PatchHunk(oldStart: 11, oldLines: 1, newStart: 11, newLines: 1, lines: ["-line11", "+changed"])
        await r.bag[0].emit(.toolResult(ToolResultMessage(
            toolUseID: "ta", isError: false, text: "ok",
            result: .edit(filePath: r.root.appendingPathComponent("f.txt").path, originalFile: before, hunks: [hunk]))))
        await r.workspace.settle()
        let edits = try #require(r.workspace.ledger.files["f.txt"]?.edits)
        let adas = try #require(edits.first { $0.author == .session(r.a.id) })
        let beas = try #require(edits.first { $0.author == .session(r.b.id) })
        #expect(r.workspace.coordinationWarnings.count == 1)
        // The other party's edit is kept; the editor's own later applied edit still holds the warning.
        r.workspace.keep(edit: beas.id, path: "f.txt")
        #expect(r.workspace.coordinationWarnings.count == 1)
        r.workspace.keep(edit: adas.id, path: "f.txt")
        #expect(r.workspace.coordinationWarnings.isEmpty)
    }

    @Test(arguments: [false, true]) func theWidestRealRowStillFitsBesideTheMarker(dark: Bool) async throws {
        let r = await WarnRig.make()
        r.a.name = "A really quite long session name indeed"
        r.a.model = "claude-sonnet-5-5"
        r.a.permissionMode = "acceptEdits"
        r.a.costUSD = 123.45
        await r.overlap()
        let w = try r.window(width: 760, dark: dark)
        try await w.runUntil { (try? w.element(identifier: "session-warning-\(r.a.id.uuidString)")) != nil }
        let row = try w.element(identifier: "session-row-\(r.a.id.uuidString)").frame
        let mark = try w.element(identifier: "session-warning-\(r.a.id.uuidString)").frame
        let menu = try w.element(identifier: "session-menu-\(r.a.id.uuidString)").frame
        let badge = try w.element(identifier: "session-mode-\(r.a.id.uuidString)").frame
        let model = try w.element(identifier: "session-model-\(r.a.id.uuidString)").frame
        #expect(row.size.width.value < 210)
        #expect(mark.origin.x.value + mark.size.width.value <= menu.origin.x.value)
        #expect(mark.origin.x.value + mark.size.width.value <= row.origin.x.value + row.size.width.value)
        #expect(mark.origin.y.value >= row.origin.y.value && mark.origin.y.value + mark.size.height.value <= row.origin.y.value + row.size.height.value)
        // The badge and model line sit left of the marker or below it: they never overlap it.
        for f in [badge, model] {
            let overlapsX = f.origin.x.value < mark.origin.x.value + mark.size.width.value && f.origin.x.value + f.size.width.value > mark.origin.x.value
            let overlapsY = f.origin.y.value < mark.origin.y.value + mark.size.height.value && f.origin.y.value + f.size.height.value > mark.origin.y.value
            #expect(!(overlapsX && overlapsY))
        }
    }
}
