import Foundation

extension Overlap {
    /// A hook reply's text is capped here; the CLI inlines up to 10,000 characters.
    public static let maxMessageCharacters = 4_000
}

/// The words a session is told about overlapping changes. Pure formatting; `Workspace.handleHook` decides who is told what.
enum OverlapNotice {
    /// One overlap's message, grouped by what the told-once store remembers it by.
    struct Item: Equatable {
        /// (edit id | tool call id | user region), without the receiver or its generation.
        var key: String
        var text: String
        /// Who the overlap is with (nil for items that are not overlaps, such as claims), and the other party's
        /// lines and ledger edit, for the user-facing warnings.
        var other: Author? = nil
        var lines: ClosedRange<Int>? = nil
        var edit: UUID? = nil
    }

    /// "lines 5\u{2013}6", or "line 5" for one line.
    static func span(_ r: ClosedRange<Int>) -> String {
        r.lowerBound == r.upperBound ? "line \(r.lowerBound)" : "lines \(r.lowerBound)\u{2013}\(r.upperBound)"
    }

    private static func ago(_ date: Date, now: Date) -> String {
        let minutes = max(0, Int(now.timeIntervalSince(date) / 60))
        if minutes == 0 { return "less than a minute ago" }
        return minutes == 1 ? "1 minute ago" : "\(minutes) minutes ago"
    }

    /// One item per edit, proposal or typing region; an edit that touches several runs near the query reports their hull.
    static func items(from overlaps: [Overlap], path: String, now: Date, name: (UUID) -> String,
                      toolID: (UUID) -> String? = { _ in nil }) -> [Item] {
        var order: [String] = []
        var grouped: [String: (first: Overlap, lines: ClosedRange<Int>?)] = [:]
        for o in overlaps {
            let key: String
            switch o.kind {
            case .active(let id): key = toolID(id).map { "tool:\($0)" } ?? "edit:\(id.uuidString)"
            case .proposed(let tool): key = "tool:\(tool)"
            case .userTyping: key = "user:\(path):" + (o.lines.map { "\($0.lowerBound)-\($0.upperBound)" } ?? "*")
            }
            if var g = grouped[key] {
                if let l = o.lines { g.lines = g.lines.map { min($0.lowerBound, l.lowerBound)...max($0.upperBound, l.upperBound) } ?? l }
                grouped[key] = g
            } else {
                order.append(key)
                grouped[key] = (o, o.lines)
            }
        }
        return order.map { key in
            let (o, lines) = grouped[key]!
            var edit: UUID?
            if case .active(let id) = o.kind { edit = id }
            return Item(key: key, text: text(for: o, lines: lines, path: AlreadyRead.oneLine(path), now: now, name: name),
                        other: o.other, lines: lines, edit: edit)
        }
    }

    private static func text(for o: Overlap, lines: ClosedRange<Int>?, path: String, now: Date, name: (UUID) -> String) -> String {
        let tail = o.diff.isEmpty ? "" : ":\n" + o.diff
        switch o.kind {
        case .userTyping:
            guard let lines else { return "The user has unsaved changes in \(path)." }
            return "The user is editing \(path) \(span(lines)) (unsaved)."
        case .proposed:
            guard let lines else { return "" }
            return "\"\(label(o.other, name))\" is about to change \(path) \(span(lines))\(tail)"
        case .active:
            guard let lines else { return "" }
            if o.other == .user { return "The user changed \(path) \(span(lines)) \(ago(o.date, now: now))\(tail)" }
            return "\"\(label(o.other, name))\" changed \(path) \(span(lines)) \(ago(o.date, now: now))\(tail)"
        }
    }

    private static func label(_ a: Author, _ name: (UUID) -> String) -> String {
        if case .session(let id) = a { return AlreadyRead.oneLine(name(id)) }
        return "The user"
    }

    /// Joins messages with blank lines, within `Overlap.maxMessageCharacters`. Whole messages only; what does not fit
    /// becomes "\u{2026}and N more" (the first message alone is cut with an ellipsis if it is too long).
    /// `included` is how many leading messages are in the text.
    static func join(_ messages: [String]) -> (text: String, included: Int) {
        let limit = Overlap.maxMessageCharacters
        func more(_ n: Int) -> String { "\n\n\u{2026}and \(n) more" }
        var text = ""
        var included = 0
        for (i, m) in messages.enumerated() {
            let rest = messages.count - i - 1
            let candidate = text.isEmpty ? m : text + "\n\n" + m
            let reserve = rest > 0 ? more(rest).count : 0
            if candidate.count + reserve <= limit {
                text = candidate; included = i + 1
            } else if i == 0 {
                text = String(m.prefix(max(limit - reserve - 1, 0))) + "\u{2026}"; included = 1
            } else { break }
        }
        let rest = messages.count - included
        if rest > 0 { text += more(rest) }
        return (text, included)
    }
}
