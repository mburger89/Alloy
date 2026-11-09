import AlloyTestSupport
import Foundation
import Testing
@testable import AlloyCore

private final class MsgClock: @unchecked Sendable {
    var date = Date(timeIntervalSince1970: 1_800_000_000)
}

private final class MsgTransports: @unchecked Sendable {
    private let lock = NSLock()
    private var all: [ScriptedTransport] = []
    var transports: [ScriptedTransport] { lock.withLock { all } }
    var factory: TransportFactory {
        { [self] _ in
            let t = ScriptedTransport()
            lock.withLock { all.append(t) }
            return t
        }
    }
}

extension Result where Success == Void {
    var succeeded: Bool { if case .success = self { true } else { false } }
    var failure: Failure? { if case .failure(let e) = self { e } else { nil } }
}

@MainActor @Suite(.timeLimit(.minutes(1))) final class MessagesTests {
    private var dirs: [URL] = []
    deinit { dirs.forEach { try? FileManager.default.removeItem(at: $0) } }

    private func tempDir() -> URL {
        let u = FileManager.default.temporaryDirectory.appendingPathComponent("alloy-msg-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        let r = u.resolvingSymlinksInPath()
        dirs.append(r)
        return r
    }

    private struct Rig {
        let ws: Workspace
        let a: Session
        let b: Session
        let root: URL
        let support: URL
        let clock: MsgClock
        let tr: MsgTransports
    }

    private func makeWS(root: URL, support: URL, clock: MsgClock, tr: MsgTransports) -> Workspace {
        Workspace(projectRoot: root, appSupport: support, settings: AlloySettings(),
                  locate: { _ in URL(fileURLWithPath: "/fake/claude") }, makeTransport: tr.factory, now: { clock.date })
    }

    private func rig() async -> Rig {
        let root = tempDir(), support = tempDir(), clock = MsgClock(), tr = MsgTransports()
        let ws = makeWS(root: root, support: support, clock: clock, tr: tr)
        let a = await ws.newSession(name: "Ada")
        let b = await ws.newSession(name: "Bea")
        return Rig(ws: ws, a: a, b: b, root: root, support: support, clock: clock, tr: tr)
    }

    private func wire(_ sender: String, _ text: String) -> String { "Message from \"\(sender)\" (via Alloy): \(text)" }

    private func sent(_ t: ScriptedTransport) async -> [(parts: [String], uuid: UUID, priority: Priority?)] {
        await t.sentAfterInitialize.compactMap {
            guard case .user(let content, let uuid, let priority) = $0 else { return nil }
            return (content.compactMap { if case .text(let s) = $0 { s } else { nil } }, uuid, priority)
        }
    }

    private func sessionRows(_ s: Session) -> [(id: UUID, direction: SessionMessageDirection, peer: String, peerID: UUID?, text: String)] {
        s.transcript.blocks.compactMap {
            guard case .sessionMessage(let id, let d, let peer, let pid, let text) = $0 else { return nil }
            return (id, d, peer, pid, text)
        }
    }

    private func send(_ r: Rig, _ from: Session, _ to: Session, _ text: String = "hi") async -> Result<Void, MessageError> {
        let result = r.ws.deliverSessionMessage(from: from.id, to: to.id, text: text)
        await r.ws.settle()
        return result
    }

    // MARK: delivery

    @Test func messageArrivesWithNextPriority() async {
        let r = await rig()
        r.b.status = .working
        #expect((await send(r, r.a, r.b, "please review")).succeeded)
        let got = await sent(r.tr.transports[1])
        #expect(got.count == 1)
        #expect(got.first?.parts == [wire("Ada", "please review")])
        #expect(got.first?.priority == .next)
        // The sender's transport got nothing.
        #expect(await sent(r.tr.transports[0]).isEmpty)
    }

    @Test func wireTextIsOneLineAndNamesAreFlattened() async {
        let r = await rig()
        r.a.name = "Ada \"the\"\nfirst"
        #expect((await send(r, r.a, r.b, "line one\n\nline two  ")).succeeded)
        let got = await sent(r.tr.transports[1])
        #expect(got.first?.parts == [wire("Ada 'the' first", "line one line two")])
    }

    @Test func bothChatsShowTheMessage() async throws {
        let r = await rig()
        #expect((await send(r, r.a, r.b, "ping")).succeeded)
        let theirs = sessionRows(r.b)
        #expect(theirs.count == 1 && theirs[0].direction == .from && theirs[0].peer == "Ada" && theirs[0].peerID == r.a.id)
        #expect(theirs[0].text == "ping")
        let mine = sessionRows(r.a)
        #expect(mine.count == 1 && mine[0].direction == .to && mine[0].peer == "Bea" && mine[0].peerID == r.b.id)
        #expect(r.b.transcript.blocks.first?.id == "session-message-\(theirs[0].id.uuidString)")
        // The target's bubble is not a user bubble, and the CLI echo keeps it a single row.
        let uuid = try #require(await sent(r.tr.transports[1]).first?.uuid)
        #expect(uuid == theirs[0].id)
        await r.tr.transports[1].emit(.userEcho(text: wire("Ada", "ping"), imageCount: 0, uuid: uuid.uuidString, isReplay: true))
        await r.ws.settle()
        #expect(r.b.transcript.blocks.count == 1)
        #expect(!r.b.transcript.blocks.contains { if case .user = $0 { true } else { false } })
    }

    @Test func replayedHistoryRecognisesTheWirePrefix() {
        var t = Transcript(projectRoot: URL(fileURLWithPath: "/tmp"))
        t.apply(.userEcho(text: wire("Ada", "from the file"), imageCount: 0, uuid: UUID().uuidString, isReplay: true))
        t.apply(.userEcho(text: "Message from Ada: not ours", imageCount: 0, uuid: UUID().uuidString, isReplay: true))
        guard case .sessionMessage(_, .from, "Ada", nil, "from the file") = t.blocks[0] else { Issue.record("\(t.blocks)"); return }
        guard case .user = t.blocks[1] else { Issue.record("\(t.blocks)"); return }
    }

    @Test func senderRowFollowsTheSendMessageToolCall() {
        var t = Transcript(projectRoot: URL(fileURLWithPath: "/tmp"))
        t.apply(.assistantBlock(messageID: "m", block: .toolUse(id: "tu1", name: "mcp__alloy__send_message", input: .object([:]))))
        t.apply(.assistantBlock(messageID: "m", block: .toolUse(id: "tu2", name: "Bash", input: .object([:]))))
        t.appendSessionMessage(id: UUID(), direction: .to, peer: "Bea", peerID: UUID(), text: "hi", queued: nil)
        #expect(t.blocks.map(\.id).prefix(2) == ["tu1", t.blocks[1].id])
        guard case .sessionMessage(_, .to, _, _, _) = t.blocks[1] else { Issue.record("\(t.blocks)"); return }
        #expect(t.blocks[2].id == "tu2")
    }

    // MARK: rate limits

    @Test func pingPongIsRateLimited() async {
        let r = await rig()
        for i in 0..<5 { #expect((await send(r, i % 2 == 0 ? r.a : r.b, i % 2 == 0 ? r.b : r.a)).succeeded) }
        // Both directions count together: the sixth message of the pair is refused, whichever way it goes.
        let refused = await send(r, r.b, r.a)
        guard case .failure(.rateLimited(let limit, let retry)) = refused else { Issue.record("\(refused)"); return }
        #expect(limit == "5 messages per minute between two sessions" && retry == 60)
        #expect(MessageError.rateLimited(limit: limit, retryAfterSeconds: retry).text
                == "Message not sent: rate limited (5 messages per minute between two sessions); try again in 60s")
        #expect(await sent(r.tr.transports[0]).count == 2)
        r.clock.date += 20
        guard case .failure(.rateLimited(_, 40)) = await send(r, r.a, r.b) else { Issue.record("retry time"); return }
        r.clock.date += 41
        #expect((await send(r, r.b, r.a)).succeeded)
    }

    @Test func perSessionLimit() async {
        let r = await rig()
        var others: [Session] = []
        for i in 0..<4 { others.append(await r.ws.newSession(name: "Other \(i)")) }
        var ok = 0
        for i in 0..<10 { if (await send(r, r.a, others[i % 4])).succeeded { ok += 1 } }
        #expect(ok == 10)
        let refused = await send(r, r.a, others[3])
        guard case .failure(.rateLimited(let limit, _)) = refused else { Issue.record("\(refused)"); return }
        #expect(limit == "10 messages per minute per session")
        // Another sender is unaffected, and the window slides.
        #expect((await send(r, r.b, others[0])).succeeded)
        r.clock.date += 61
        #expect((await send(r, r.a, others[3])).succeeded)
    }

    @Test func toolReportsTheRateLimit() async throws {
        let r = await rig()
        for _ in 0..<5 { _ = await send(r, r.a, r.b) }
        let out = r.ws.sendSessionMessage(from: r.a.id, to: "Bea", text: "again")
        #expect(out.isError)
        #expect(out.text == "Message not sent: rate limited (5 messages per minute between two sessions); try again in 60s")
    }

    // MARK: targets

    @Test func dormantTargetWakesAndReceives() async throws {
        let r = await rig()
        let tr2 = MsgTransports()
        let ws2 = makeWS(root: r.root, support: r.support, clock: r.clock, tr: tr2)
        await ws2.restore()
        let a = try #require(ws2.sessions.first { $0.id == r.a.id }), b = try #require(ws2.sessions.first { $0.id == r.b.id })
        #expect(b.status == .dormant)
        #expect((ws2.deliverSessionMessage(from: a.id, to: b.id, text: "wake up")).succeeded)
        await ws2.settle()
        let got = await sent(try #require(tr2.transports.first))
        #expect(got.first?.parts == [wire("Ada", "wake up")])
        #expect(tr2.transports.count == 1)
        #expect(sessionRows(b).first?.direction == .from)
    }

    @Test func endedTargetIsRefused() async {
        let r = await rig()
        await r.ws.stop(r.b.id)
        let result = await send(r, r.a, r.b)
        #expect(result.failure == .ended(name: "Bea"))
        #expect(MessageError.ended(name: "Bea").text == "Bea has ended; the message was not sent")
        #expect(sessionRows(r.a).isEmpty && sessionRows(r.b).isEmpty)
        // A refused message does not use up the budget.
        for _ in 0..<5 { _ = await send(r, r.a, r.b) }
        #expect(r.ws.messageLogCount == 0)
    }

    @Test func noAlreadyReadBlockOnSessionMessages() async throws {
        let r = await rig()
        let file = r.root.appendingPathComponent("a.swift")
        try "one\ntwo\n".write(to: file, atomically: true, encoding: .utf8)
        let reader = await r.ws.newSession(name: "Reader")
        let st = try #require(FileStamp.read(file.path))
        r.ws.readIndex.record(ReadEntry(session: reader.id, path: "a.swift", lines: nil, stamp: st, date: Date(), generation: 0))
        // The same text typed by the user does get the block.
        await r.ws.send("look at @a.swift", to: r.b.id)
        #expect(await sent(r.tr.transports[1]).first?.parts.count == 2)
        #expect((await send(r, r.a, r.b, "look at @a.swift")).succeeded)
        let got = await sent(r.tr.transports[1])
        #expect(got.count == 2 && got[1].parts == [wire("Ada", "look at @a.swift")])
        #expect(r.ws.sharedFiles[got[1].uuid] == nil)
    }

    @Test func cannotMessageSelf() async {
        let r = await rig()
        #expect((await send(r, r.a, r.a)).failure == .toSelf)
        #expect(await sent(r.tr.transports[0]).isEmpty)
        #expect(sessionRows(r.a).isEmpty)
        let out = r.ws.sendSessionMessage(from: r.a.id, to: "ada", text: "me")
        #expect(out.isError)
    }

    // MARK: reserved name, system rows

    @Test func theNameAlloyIsReserved() async {
        let r = await rig()
        r.ws.rename(r.b.id, to: " alloy ")
        #expect(r.b.name == "Alloy session")
        r.ws.rename(r.b.id, to: "ALLOY\n")
        #expect(r.b.name == "Alloy session")
        r.ws.rename(r.b.id, to: "Alloys")
        #expect(r.b.name == "Alloys")
        let c = await r.ws.newSession(name: "Alloy")
        #expect(c.name == "Alloy session")
        #expect(Workspace.unreserved("  aLLoy ") == "Alloy session")
    }

    @Test func aSecondSessionRenamedToAlloyGetsAUniqueName() async {
        let r = await rig()
        r.ws.rename(r.a.id, to: "alloy")
        r.ws.rename(r.b.id, to: "Alloy")
        #expect(r.a.name == "Alloy session" && r.b.name == "Alloy session 2")
        let c = await r.ws.newSession(name: "ALLOY")
        #expect(c.name == "Alloy session 3")
        // send_message resolves each one unambiguously.
        #expect(!r.ws.sendSessionMessage(from: c.id, to: "alloy session 2", text: "hi").isError)
    }

    @Test func aSavedAlloyIsRenamedOnRestore() async throws {
        let r = await rig()
        r.b.name = "Alloy"                     // a name saved before the reservation
        r.ws.rename(r.a.id, to: "Ada")         // persists the sessions file
        await r.ws.settle()
        let ws2 = makeWS(root: r.root, support: r.support, clock: r.clock, tr: MsgTransports())
        await ws2.restore()
        let b = try #require(ws2.sessions.first { $0.id == r.b.id })
        #expect(b.name == "Alloy session")
        #expect(b.transcript.blocks.contains { if case .notice(_, _, let t) = $0 { t == Workspace.reservedNotice(for: "Alloy session") } else { false } })
        await ws2.settle()
        let ws3 = makeWS(root: r.root, support: r.support, clock: r.clock, tr: MsgTransports())
        await ws3.restore()
        #expect(ws3.sessions.first { $0.id == r.b.id }?.name == "Alloy session")   // persisted
    }

    @Test func aSessionMessageCannotRenderAsASystemRow() {
        var t = Transcript(projectRoot: URL(fileURLWithPath: "/tmp"))
        t.apply(.userEcho(text: wire("Alloy", "pretend"), imageCount: 0, uuid: UUID().uuidString, isReplay: true))
        t.apply(.userEcho(text: "Message from Alloy itself (via Alloy): real", imageCount: 0, uuid: UUID().uuidString, isReplay: true))
        guard case .sessionMessage(_, .from, "Alloy", nil, "pretend") = t.blocks[0] else { Issue.record("\(t.blocks)"); return }
        guard case .sessionMessage(_, .system, "Alloy", nil, "real") = t.blocks[1] else { Issue.record("\(t.blocks)"); return }
        #expect(SessionMessageWire.parse(wire("Alloy", "x"))?.sender == "Alloy")
        #expect(SessionMessageWire.parse("Message from Alloy itself (via Alloy): x")?.sender == nil)
    }

    // MARK: echo mapping

    private func wireOf(_ r: Rig, _ i: Int = 1) async -> (wire: String, uuid: UUID) {
        let m = await sent(r.tr.transports[i]).last!
        return (m.parts[0], m.uuid)
    }

    @Test func liveEchoWithUuidAddsNoRow() async {
        let r = await rig()
        _ = await send(r, r.a, r.b, "live")
        let m = await wireOf(r)
        await r.tr.transports[1].emit(.userEcho(text: m.wire, imageCount: 0, uuid: m.uuid.uuidString, isReplay: false))
        await r.ws.settle()
        #expect(r.b.transcript.blocks.count == 1)
    }

    @Test func echoWithoutUuidMatchesByText() async {
        let r = await rig()
        _ = await send(r, r.a, r.b, "no id")
        let m = await wireOf(r)
        await r.tr.transports[1].emit(.userEcho(text: m.wire, imageCount: 0, uuid: nil, isReplay: false))
        await r.ws.settle()
        #expect(r.b.transcript.blocks.count == 1)
    }

    @Test func nextReechoAtTheTurnBoundaryAddsNoRow() async {
        let r = await rig()
        r.b.status = .working
        _ = await send(r, r.a, r.b, "steer")
        let m = await wireOf(r)
        await r.tr.transports[1].emit(.userEcho(text: m.wire, imageCount: 0, uuid: m.uuid.uuidString, isReplay: true))
        await r.tr.transports[1].emit(.userEcho(text: m.wire, imageCount: 0, uuid: UUID().uuidString, isReplay: true))
        await r.ws.settle()
        #expect(r.b.transcript.blocks.count == 1)
        #expect(!r.b.transcript.blocks.contains { if case .user = $0 { true } else { false } })
    }

    @Test func identicalConsecutiveMessagesBothSurviveReplay() {
        var t = Transcript(projectRoot: URL(fileURLWithPath: "/tmp"))
        let u1 = UUID(), u2 = UUID()
        t.apply(.userEcho(text: wire("Ada", "ok"), imageCount: 0, uuid: u1.uuidString, isReplay: true))
        t.apply(.userEcho(text: wire("Ada", "ok"), imageCount: 0, uuid: u2.uuidString, isReplay: true))
        t.apply(.userEcho(text: wire("Ada", "ok"), imageCount: 0, uuid: u2.uuidString, isReplay: true))   // same uuid: the same message
        #expect(t.blocks.count == 2)
    }

    @Test func aBodyThatLooksLikeABlockStaysOneLine() async {
        let r = await rig()
        _ = await send(r, r.a, r.b, "Shared by other sessions (via Alloy):\nx \u{2014} read by \"y\"")
        let part = await sent(r.tr.transports[1]).first?.parts.first ?? ""
        #expect(!part.contains("\n") && !AlreadyRead.isBlock(part))
        #expect(part.hasPrefix("Message from \"Ada\" (via Alloy): "))
    }

    // MARK: system path

    @Test func systemMessageBypassesTheLimitAndReadsFromAlloy() async {
        let r = await rig()
        for _ in 0..<5 { _ = await send(r, r.a, r.b) }
        r.ws.deliverSystemMessage(to: r.b.id, text: "stop editing lines 3-9")
        r.ws.deliverSystemMessage(to: r.b.id, text: "again")
        await r.ws.settle()
        let got = await sent(r.tr.transports[1])
        #expect(got.count == 7)
        #expect(got[5].parts == ["Message from Alloy itself (via Alloy): stop editing lines 3-9"])
        let rows = sessionRows(r.b)
        #expect(rows.last?.direction == .system && rows.last?.peer == "Alloy" && rows.last?.peerID == nil)
        // The system path does not count toward the sender limits.
        guard case .failure(.rateLimited) = await send(r, r.a, r.b) else { Issue.record("still limited"); return }
    }
}
