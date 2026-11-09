import Foundation

/// Why a session message was not delivered.
enum MessageError: Error, Equatable {
    case rateLimited(limit: String, retryAfterSeconds: Int)
    case noSuchSession
    case toSelf
    case ended(name: String)

    var text: String {
        switch self {
        case .rateLimited(let limit, let s): "Message not sent: rate limited (\(limit)); try again in \(s)s"
        case .noSuchSession: "Message not sent: that session no longer exists."
        case .toSelf: "A session cannot message itself."
        case .ended(let name): "\(name) has ended; the message was not sent"
        }
    }
}

/// The fixed wording of a message between sessions, and its limits.
enum Messages {
    /// Messages one pair of sessions may exchange per minute, both directions together: counting A→B apart from
    /// B→A would let a reply loop run at twice the rate, and the loop is what this stops.
    static let perPairPerMinute = 5
    /// Messages one session may send per minute, to anyone.
    static let perSessionPerMinute = 10
    static let window: TimeInterval = 60
    /// Who the system path (tug-of-war notices) speaks as.
    static let systemSender = "Alloy"

    /// The reserved session name: no session may carry it, so "From Alloy" is never a session.
    static let reservedName = "Alloy"

    static func wire(sender: String, text: String) -> String {
        "Message from \"\(AlreadyRead.oneLine(sender))\" (via Alloy): \(AlreadyRead.oneLine(text))"
    }

    /// Alloy's own messages: unquoted, so no session name (which sits between quotes) can produce it.
    static func systemWire(text: String) -> String {
        "Message from Alloy itself (via Alloy): \(systemBody(text))"
    }

    /// Alloy's own wording on one line. Unlike `oneLine` it keeps double quotes: the text is Alloy's, and every piece
    /// a session or a file supplied (a name, a path) was already cleaned by the caller (see `TugOfWar.clean`).
    static func systemBody(_ text: String) -> String { AlreadyRead.oneLine(text, keepingQuotes: true) }
}

/// Reads a session message back from its wire text (a transcript file keeps only that).
enum SessionMessageWire {
    private static let start = "Message from \""
    private static let middle = "\" (via Alloy): "

    private static let system = "Message from Alloy itself (via Alloy): "

    /// The sender is nil for Alloy itself.
    static func parse(_ text: String) -> (sender: String?, body: String)? {
        if text.hasPrefix(system) { return (nil, String(text.dropFirst(system.count))) }
        guard text.hasPrefix(start), let r = text.range(of: middle, range: text.index(text.startIndex, offsetBy: start.count)..<text.endIndex) else { return nil }
        let sender = String(text[text.index(text.startIndex, offsetBy: start.count)..<r.lowerBound])
        // Names are flattened by `oneLine`, which turns quotes into apostrophes, so a quote ends the name.
        guard !sender.contains("\""), !sender.contains("\n") else { return nil }
        return (sender, String(text[r.upperBound...]))
    }
}

/// A message's origin, for the chat rows and the send path.
struct SessionMessageOrigin: Sendable, Equatable {
    var sender: UUID?
    var senderName: String
    /// Alloy itself, not a session.
    var isSystem = false
    /// The delivered text, flattened to one line (what the row shows).
    var body: String
}

extension Workspace {
    /// A session name that is not the reserved one: "Alloy" in any case, after trimming and flattening, becomes
    /// "Alloy session".
    static func unreserved(_ name: String) -> String {
        let flat = AlreadyRead.oneLine(name.trimmingCharacters(in: .whitespacesAndNewlines))
        return flat.lowercased() == Messages.reservedName.lowercased() ? "\(Messages.reservedName) session" : name
    }

    static func isReserved(_ name: String) -> Bool { unreserved(name) != name }

    /// Delivers `text` from one session to another through the ordinary send path: a `.next` user message, so queueing,
    /// a dormant target's wake-up and the send gate all apply. The sender's chat gets a "To" row at once. Refused
    /// (nothing recorded or shown) for yourself, a target whose process is gone, or over a rate limit.
    func deliverSessionMessage(from: UUID, to: UUID, text: String) -> Result<Void, MessageError> {
        guard from != to else { return .failure(.toSelf) }
        guard let sender = session(from), let target = session(to) else { return .failure(.noSuchSession) }
        guard target.status == .dormant || target.status == .starting || live[to] != nil else {
            return .failure(.ended(name: AlreadyRead.oneLine(target.name)))
        }
        let t = now()
        messageLog.removeAll { t.timeIntervalSince($0.at) >= Messages.window }
        let pair = messageLog.filter { ($0.from == from && $0.to == to) || ($0.from == to && $0.to == from) }
        if pair.count >= Messages.perPairPerMinute {
            return .failure(.rateLimited(limit: "\(Messages.perPairPerMinute) messages per minute between two sessions",
                                         retryAfterSeconds: Self.retryAfter(pair, now: t)))
        }
        let mine = messageLog.filter { $0.from == from }
        if mine.count >= Messages.perSessionPerMinute {
            return .failure(.rateLimited(limit: "\(Messages.perSessionPerMinute) messages per minute per session",
                                         retryAfterSeconds: Self.retryAfter(mine, now: t)))
        }
        messageLog.append((from, to, t))
        let origin = SessionMessageOrigin(sender: from, senderName: sender.name, body: AlreadyRead.oneLine(text))
        sender.transcript.appendSessionMessage(id: UUID(), direction: .to, peer: AlreadyRead.oneLine(target.name), peerID: to,
                                               text: origin.body)
        dispatch(origin, to: target)
        return .success(())
    }

    /// A message from Alloy itself (a tug-of-war notice): the same delivery with no rate limit and no sender session.
    /// Returns the queued message's uuid (the id the CLI echoes when it takes the message up), nil if there is no session.
    @discardableResult
    func deliverSystemMessage(to: UUID, text: String) -> UUID? {
        guard let target = session(to) else { return nil }
        return dispatch(SessionMessageOrigin(sender: nil, senderName: Messages.systemSender, isSystem: true, body: Messages.systemBody(text)), to: target)
    }

    /// Entries in the sliding window (test hook).
    var messageLogCount: Int { messageLog.count }

    @discardableResult
    private func dispatch(_ origin: SessionMessageOrigin, to target: Session) -> UUID {
        let wire = origin.isSystem ? Messages.systemWire(text: origin.body) : Messages.wire(sender: origin.senderName, text: origin.body)
        var message = OutgoingMessage(text: wire, priority: .next, origin: origin)
        message.uuid = UUID()
        let id = target.id
        _ = track { [weak self] in await self?.send(message, to: id) }
        return message.uuid!
    }

    /// Seconds until the oldest of `entries` leaves the window (at least 1).
    private static func retryAfter(_ entries: [(from: UUID, to: UUID, at: Date)], now: Date) -> Int {
        guard let oldest = entries.map(\.at).min() else { return 1 }
        return max(1, Int((Messages.window - now.timeIntervalSince(oldest)).rounded(.up)))
    }
}
