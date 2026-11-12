import Foundation
import MetalUI
import MetalUICodeBuffer
import SwiftTreeSitter

/// What a highlight run is, independent of colour.
public enum SyntaxToken: Sendable, Hashable, CaseIterable {
    case keyword, string, comment, number, type, function, variable, property, constant, builtin
    case operator_, punctuation, attribute, tag, heading, link, plain

    /// The token a tree-sitter capture name maps to, by its first dotted component (`function.method` is
    /// `.function`); `nil` for captures that do not colour text (`spell`, `none`, `embedded`).
    static func forCapture(_ components: [String]) -> SyntaxToken? {
        guard let first = components.first else { return nil }
        let second = components.count > 1 ? components[1] : ""
        switch first {
        case "keyword", "conditional", "repeat", "include", "exception", "storageclass", "media", "import",
             "supports", "keyframes", "charset", "preproc", "define": return .keyword
        case "string", "character", "escape": return .string
        case "comment": return .comment
        case "number", "float": return .number
        case "type", "constructor", "namespace", "module": return .type
        case "function", "method": return .function
        case "variable": return second == "builtin" ? .builtin : .variable
        case "property", "field", "parameter": return .property
        case "constant", "boolean": return second == "builtin" ? .builtin : .constant
        case "builtin": return .builtin
        case "operator": return .operator_
        case "punctuation", "delimiter": return .punctuation
        case "attribute", "annotation", "decorator": return .attribute
        case "tag": return .tag
        case "label": return .variable
        case "heading": return .heading
        case "text", "markup":
            switch second {
            case "title", "heading": return .heading
            case "uri", "link", "reference", "url": return .link
            default: return nil
            }
        default: return nil
        }
    }
}

/// The pure part of highlighting: a tree and its text in, flattened `(bytes, token)` runs out.
enum HighlightCore {
    /// Parses `bytes[start..<end]` (default: all of it) as a standalone document, so tree offsets are relative to `start`.
    static func parse(_ parser: Parser, old: MutableTree?, bytes: [UInt8], start: Int = 0, end: Int? = nil) -> MutableTree? {
        let limit = min(end ?? bytes.count, bytes.count)
        // Encoding 0 is TSInputEncodingUTF8: every offset tree-sitter reports is a UTF-8 byte.
        return parser.parse(tree: old, encoding: .init(0)) { offset, _ in
            let at = start + offset
            guard at < limit else { return nil }
            return Data(bytes[at..<min(at + 8192, limit)])
        }
    }

    private struct Capture {
        var lower: Int
        var upper: Int
        var token: SyntaxToken
        var priority: Int
    }

    /// The runs covering `range` of `bytes`. A later pattern in the query wins where captures overlap; runs
    /// are sorted and disjoint, and adjacent runs of one token are joined. `base` is the offset in `bytes` of the
    /// tree's byte 0 (non-zero for a tree parsed from a window); `range` and the results are in `bytes` coordinates.
    static func runs(tree: MutableTree, query: Query, bytes: [UInt8], range: Range<Int>, base: Int = 0) -> [(Range<Int>, SyntaxToken)] {
        let lo = max(base, range.lowerBound), hi = min(bytes.count, range.upperBound)
        guard lo < hi, let root = tree.rootNode else { return [] }
        let cursor = query.execute(node: root, in: tree)
        cursor.setByteRange(range: UInt32(lo - base)..<UInt32(hi - base))
        var captures: [Capture] = []
        while let match = cursor.next() {
            if !match.predicates.isEmpty && !allows(match, bytes: bytes, base: base) { continue }
            for capture in match.captures {
                guard let token = SyntaxToken.forCapture(capture.nameComponents) else { continue }
                let r = capture.node.byteRange
                let a = max(lo, Int(r.lowerBound) + base), b = min(hi, Int(r.upperBound) + base)
                if a < b { captures.append(Capture(lower: a, upper: b, token: token, priority: match.patternIndex)) }
            }
        }
        return flatten(captures)
    }

    private static func allows(_ match: QueryMatch, bytes: [UInt8], base: Int) -> Bool {
        for predicate in match.predicates {
            switch predicate {
            case .set, .generic, .isNot: continue
            default:
                for capture in predicate.captures(in: match) {
                    let r = capture.node.byteRange
                    let text = String(decoding: bytes[base + Int(r.lowerBound)..<min(bytes.count, base + Int(r.upperBound))], as: UTF8.self)
                    if !predicate.evalulate(with: text) { return false }
                }
            }
        }
        return true
    }

    private static func flatten(_ captures: [Capture]) -> [(Range<Int>, SyntaxToken)] {
        if captures.isEmpty { return [] }
        var bounds = Set<Int>()
        for c in captures { bounds.insert(c.lower); bounds.insert(c.upper) }
        let points = bounds.sorted()
        var winner = [Int](repeating: -1, count: points.count - 1)   // index into `ordered`
        let ordered = captures.enumerated().sorted {
            $0.element.priority != $1.element.priority ? $0.element.priority < $1.element.priority : $0.offset < $1.offset
        }.map(\.element)
        for (index, c) in ordered.enumerated() {
            guard var i = lowerBound(points, c.lower) else { continue }
            while i < points.count - 1, points[i] < c.upper {
                winner[i] = index
                i += 1
            }
        }
        var out: [(Range<Int>, SyntaxToken)] = []
        for i in 0..<winner.count where winner[i] >= 0 {
            let token = ordered[winner[i]].token
            let r = points[i]..<points[i + 1]
            if let last = out.last, last.0.upperBound == r.lowerBound, last.1 == token {
                out[out.count - 1].0 = last.0.lowerBound..<r.upperBound
            } else {
                out.append((r, token))
            }
        }
        return out
    }

    private static func lowerBound(_ points: [Int], _ value: Int) -> Int? {
        var lo = 0, hi = points.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if points[mid] < value { lo = mid + 1 } else { hi = mid }
        }
        return lo < points.count ? lo : nil
    }
}

/// Parses documents off the main actor and answers highlight captures for byte ranges. It owns one parser
/// and tree per document id; edits reparse incrementally.
public actor HighlightEngine {
    /// A parse of `bytes[start..<end]` as a standalone document (large documents only); tree offsets are relative to
    /// `start` and tree rows to `startRow`.
    private struct Window {
        var start: Int
        var end: Int
        var startRow: Int
        var tree: MutableTree
        /// The text of `start..<end`: all the bytes a windowed document keeps of itself.
        var bytes: [UInt8]
    }

    private struct Document {
        var support: LanguageSupport
        var parser: Parser
        /// The whole-file tree; `nil` for a windowed (large) document.
        var tree: MutableTree?
        var windowed = false
        var window: Window?
        /// The whole text; empty for a windowed document, which reads `snapshot` and keeps only its window's bytes.
        var bytes: [UInt8]
        /// The text of a windowed document (a rope shared with the buffer, so it costs no second copy of the file).
        var snapshot: CodeSnapshot?
        /// The buffer version `bytes` is the text of.
        var version: UInt64
    }

    private struct Waiter {
        var token: UInt64
        var minVersion: UInt64
        var continuation: CheckedContinuation<Void, Never>
        var timeout: Task<Void, Never>
    }

    private var documents: [UUID: Document] = [:]
    private var waiters: [UUID: [Waiter]] = [:]
    private var nextToken: UInt64 = 0
    private let waitTimeout: Duration
    private let windowedThreshold: Int
    private let windowMargin: Int

    /// `waitTimeout` bounds how long ``captures(id:byteRange:minVersion:)`` waits for the engine to reach a version.
    ///
    /// Documents of more than `windowedThreshold` bytes are never parsed whole (a whole-file tree costs ~60 bytes
    /// per source byte): the engine parses one window of the text around the last requested range, `windowMargin`
    /// bytes each side, and re-parses a new one when a request falls outside it.
    ///
    /// Accepted limitation: a window is parsed as a standalone document, so colours at its very top can be wrong
    /// when it starts inside a multi-line string or comment. Snapping the start to a likely top-level line makes
    /// that rare.
    public init(waitTimeout: Duration = .seconds(2), windowedThreshold: Int = 1_048_576, windowMargin: Int = 65_536) {
        self.waitTimeout = waitTimeout
        self.windowedThreshold = windowedThreshold
        self.windowMargin = windowMargin
    }

    /// How many `captures` calls are suspended waiting for a version (test observability).
    var waiterCount: Int { waiters.values.reduce(0) { $0 + $1.count } }

    /// Starts tracking `id`, parsing `text` (the text of buffer `version`) as `language`.
    public func open(id: UUID, language: Language, text: String, version: UInt64) async {
        await open(id: id, language: language, snapshot: CodeBuffer(text).snapshot(), version: version)
    }

    /// Starts tracking `id`, parsing `snapshot` (the text of buffer `version`) as `language`. A document above the
    /// windowed threshold keeps `snapshot` itself, not a copy of its bytes.
    public func open(id: UUID, language: Language, snapshot: CodeSnapshot, version: UInt64) async {
        let support = LanguageSupport.of(language)
        let parser = Parser()
        do {
            try parser.setLanguage(support.language)
        } catch {
            LanguageSupport.report("grammar for \(language) rejected by the parser: \(error)", key: "set-\(language)")
        }
        let windowed = snapshot.utf8Count > windowedThreshold
        let bytes = windowed ? [] : snapshot.utf8(in: 0..<snapshot.utf8Count)
        let tree = windowed ? nil : HighlightCore.parse(parser, old: nil, bytes: bytes)
        documents[id] = Document(support: support, parser: parser, tree: tree, windowed: windowed, bytes: bytes,
                                 snapshot: windowed ? snapshot : nil, version: version)
        resumeWaiters(id)
    }

    /// Applies `edits` (in order, each in the coordinates of the text just before it) and reparses
    /// incrementally; `newText` is the text after all of them, which is buffer `version`.
    public func edit(id: UUID, edits: [CodeEdit], newText: String, version: UInt64) async {
        await edit(id: id, edits: edits, snapshot: CodeBuffer(newText).snapshot(), version: version)
    }

    /// Like ``edit(id:edits:newText:version:)``, with the text after the edits as a snapshot.
    public func edit(id: UUID, edits: [CodeEdit], snapshot: CodeSnapshot, version: UInt64) async {
        guard var doc = documents[id] else { return }
        if doc.windowed {
            editWindowed(&doc, edits: edits, snapshot: snapshot, version: version)
            documents[id] = doc
            resumeWaiters(id)
            return
        }
        if let tree = doc.tree {
            for e in edits {
                tree.edit(InputEdit(
                    startByte: e.range.lowerBound, oldEndByte: e.range.upperBound,
                    newEndByte: e.range.lowerBound + e.newText.utf8.count,
                    startPoint: Point(row: e.startPoint.row, column: e.startPoint.column),
                    oldEndPoint: Point(row: e.oldEndPoint.row, column: e.oldEndPoint.column),
                    newEndPoint: Point(row: e.newEndPoint.row, column: e.newEndPoint.column)))
            }
        }
        doc.bytes = snapshot.utf8(in: 0..<snapshot.utf8Count)
        doc.version = version
        doc.tree = HighlightCore.parse(doc.parser, old: doc.tree, bytes: doc.bytes)
        documents[id] = doc
        resumeWaiters(id)
    }

    /// The version `captures` answers for an id the engine does not hold.
    public static let unknownVersion = UInt64.max

    /// The runs inside `byteRange` of the document's text (sorted, disjoint, UTF-8 byte offsets) and the buffer
    /// version that text is. A caller applies them only to a snapshot of that same version.
    ///
    /// If the engine's text is older than `minVersion` (its `edit` has not arrived yet) the call suspends, without
    /// holding the actor, until an `edit` or `open` brings it there, or until the wait times out (then it answers
    /// from the text it has, and the caller's version check drops the answer). `close` ends the wait with
    /// ``unknownVersion``.
    public func captures(id: UUID, byteRange: Range<Int>, minVersion: UInt64 = 0)
        async -> (version: UInt64, runs: [(Range<Int>, SyntaxToken)]) {
        if let doc = documents[id], doc.version < minVersion { await waitForVersion(id: id, minVersion: minVersion) }
        guard let doc = documents[id] else { return (Self.unknownVersion, []) }
        guard let query = doc.support.highlights else { return (doc.version, []) }
        if doc.windowed {
            guard let snapshot = doc.snapshot else { return (doc.version, []) }
            let range = max(0, byteRange.lowerBound)..<max(0, min(snapshot.utf8Count, byteRange.upperBound))
            guard range.lowerBound < range.upperBound else { return (doc.version, []) }
            let window: Window
            if let w = doc.window, w.start <= range.lowerBound, range.upperBound <= w.end {
                window = w
            } else {
                guard let w = makeWindow(doc, snapshot: snapshot, around: range) else { return (doc.version, []) }
                documents[id]?.window = w
                window = w
            }
            let local = (range.lowerBound - window.start)..<(range.upperBound - window.start)
            let runs = HighlightCore.runs(tree: window.tree, query: query, bytes: window.bytes, range: local)
            return (doc.version, runs.map { (($0.0.lowerBound + window.start)..<($0.0.upperBound + window.start), $0.1) })
        }
        guard let tree = doc.tree else { return (doc.version, []) }
        return (doc.version, HighlightCore.runs(tree: tree, query: query, bytes: doc.bytes, range: byteRange))
    }

    /// A window around `range`: `windowMargin` each side, the start snapped back to a likely top-level line, the end
    /// forward to a line end.
    private func makeWindow(_ doc: Document, snapshot: CodeSnapshot, around range: Range<Int>) -> Window? {
        let count = snapshot.utf8Count
        let newline = UInt8(ascii: "\n")
        var start = max(0, range.lowerBound - windowMargin)
        var end = min(count, range.upperBound + windowMargin)
        func lineStart(_ i: Int) -> Int { i - snapshot.point(at: i).column }
        func isTopLevel(_ i: Int) -> Bool {
            guard i < count else { return false }
            switch snapshot.byte(at: i) {
            case newline, UInt8(ascii: " "), UInt8(ascii: "\t"), UInt8(ascii: "\r"),
                 UInt8(ascii: "}"), UInt8(ascii: ")"), UInt8(ascii: "]"): return false
            default: return true
            }
        }
        start = lineStart(start)
        let floor = max(0, start - windowMargin)
        var probe = start
        while probe > floor, !isTopLevel(probe) { probe = lineStart(probe - 1) }
        if isTopLevel(probe) { start = probe }
        // Forward to the end of the line holding the last byte (the start of the next row).
        if end < count, end > 0, snapshot.byte(at: end - 1) != newline {
            end = snapshot.offset(of: CodePoint(row: snapshot.point(at: end - 1).row + 1, column: 0))
        }
        let startRow = snapshot.point(at: start).row
        let bytes = snapshot.utf8(in: start..<end)
        guard let tree = HighlightCore.parse(doc.parser, old: nil, bytes: bytes) else { return nil }
        return Window(start: start, end: end, startRow: startRow, tree: tree, bytes: bytes)
    }

    /// Large documents: keeps the window tree in step when every edit lies inside it, otherwise drops the window.
    private func editWindowed(_ doc: inout Document, edits: [CodeEdit], snapshot: CodeSnapshot, version: UInt64) {
        doc.snapshot = snapshot
        doc.version = version
        guard var window = doc.window else { return }
        for e in edits {
            guard e.range.lowerBound >= window.start, e.range.upperBound <= window.end else {
                doc.window = nil
                return
            }
            let added = e.newText.utf8.count
            window.tree.edit(InputEdit(
                startByte: e.range.lowerBound - window.start, oldEndByte: e.range.upperBound - window.start,
                newEndByte: e.range.lowerBound - window.start + added,
                startPoint: Point(row: e.startPoint.row - window.startRow, column: e.startPoint.column),
                oldEndPoint: Point(row: e.oldEndPoint.row - window.startRow, column: e.oldEndPoint.column),
                newEndPoint: Point(row: e.newEndPoint.row - window.startRow, column: e.newEndPoint.column)))
            window.end += added - (e.range.upperBound - e.range.lowerBound)
        }
        guard window.end <= snapshot.utf8Count else { doc.window = nil; return }
        let bytes = snapshot.utf8(in: window.start..<window.end)
        guard let tree = HighlightCore.parse(doc.parser, old: window.tree, bytes: bytes) else { doc.window = nil; return }
        window.tree = tree
        window.bytes = bytes
        doc.window = window
    }

    /// Forgets `id`; its waiting `captures` calls answer ``unknownVersion``.
    public func close(id: UUID) {
        documents[id] = nil
        resumeWaiters(id)
    }

    private func waitForVersion(id: UUID, minVersion: UInt64) async {
        nextToken += 1
        let token = nextToken
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let limit = waitTimeout
            let timeout = Task { [weak self] in
                try? await Task.sleep(for: limit)
                if !Task.isCancelled { await self?.expire(id: id, token: token) }
            }
            waiters[id, default: []].append(Waiter(token: token, minVersion: minVersion, continuation: continuation, timeout: timeout))
        }
    }

    /// Resumes the waiters of `id` whose version the document has reached (all of them if it is gone).
    private func resumeWaiters(_ id: UUID) {
        guard let list = waiters[id] else { return }
        let version = documents[id]?.version
        let (ready, rest) = list.reduce(into: ([Waiter](), [Waiter]())) { acc, w in
            if let version, version < w.minVersion { acc.1.append(w) } else { acc.0.append(w) }
        }
        waiters[id] = rest.isEmpty ? nil : rest
        for w in ready {
            w.timeout.cancel()
            w.continuation.resume()
        }
    }

    private func expire(id: UUID, token: UInt64) {
        guard var list = waiters[id], let index = list.firstIndex(where: { $0.token == token }) else { return }
        let w = list.remove(at: index)
        waiters[id] = list.isEmpty ? nil : list
        w.continuation.resume()
    }
}
