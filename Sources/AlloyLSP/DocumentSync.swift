import AlloyCore
import Foundation
import MetalUICodeBuffer

public enum DocumentChange: Sendable {
    /// Edits since the previously synced text, and the snapshot after the last of them.
    case edits([CodeEdit], after: CodeSnapshot)
    case resync(CodeSnapshot)
}

/// Mirrors open documents to one language server: didOpen/didChange/didSave/didClose, strictly in order.
///
/// `apply` and friends only record state and enqueue; a single pump task converts and sends, so nothing
/// reorders while the actor is suspended waiting for the server. Consecutive changes to one document that
/// have not been sent yet are coalesced into one `didChange`.
public actor DocumentSync {
    public static let maxFileBytes = 1_048_576
    static let historyLimit = 8
    /// Batches with more edits than this are sent as whole text when positions need scratch conversion.
    static let scratchEditLimit = 64

    private struct Document {
        var languageID: String
        var current: CodeSnapshot
        var history: [CodeSnapshot]   // oldest first, includes `current`
    }

    private enum Op {
        case open(uri: URL)
        case change(uri: URL, steps: [Step])
        case save(uri: URL)
        case close(uri: URL)

        var uri: URL {
            switch self {
            case .open(let u), .change(let u, _), .save(let u), .close(let u): u
            }
        }
    }

    private enum Step {
        case edits([CodeEdit], before: CodeSnapshot, after: CodeSnapshot)
        case full(CodeSnapshot)

        var version: Int {
            switch self {
            case .edits(_, _, let after): Int(after.version)
            case .full(let s): Int(s.version)
            }
        }
    }

    /// Pending change steps per document beyond which they collapse into one whole-text change.
    static let maxPendingSteps = 64

    private let server: LanguageServer
    private var documents: [URL: Document] = [:]
    private var queue: [Op] = []
    private var pumping = false
    private var idleWaiters: [UUID: CheckedContinuation<Void, Never>] = [:]
    private var pumpTask: Task<Void, Never>?
    /// Set by ``shutdown()``: the server was stopped for good, so nothing is sent and nothing waits any more.
    private var stopped = false
    /// Test hook: while set, the pump sends nothing (ops keep coalescing in the queue).
    private var paused = false
    /// The connection the `opened` set belongs to. A different connection means a restarted server, which
    /// has opened nothing yet.
    private var lastConnection: JSONRPCConnection?
    /// Documents the current server instance has received a didOpen for.
    private var opened: Set<URL> = []

    public init(server: LanguageServer) {
        self.server = server
    }

    // MARK: - Public API

    public func open(uri: URL, languageID: String, snapshot: CodeSnapshot) async {
        guard !stopped else { return }
        guard snapshot.utf8Count <= Self.maxFileBytes else {
            if documents[uri] != nil { drop(uri) }   // a tracked file that is now too large leaves the server
            return
        }
        if var doc = documents[uri] {
            // Already tracked: bring the server to this text.
            doc.languageID = languageID
            documents[uri] = doc
            record(snapshot, for: uri)
            enqueue(.full(snapshot), for: uri)
        } else {
            documents[uri] = Document(languageID: languageID, current: snapshot, history: [snapshot])
            queue.append(.open(uri: uri))
        }
        startPump()
    }

    public func apply(uri: URL, change: DocumentChange) async {
        guard !stopped, let doc = documents[uri] else { return }
        let step: Step
        let after: CodeSnapshot
        switch change {
        case .edits(let edits, let snapshot):
            if edits.isEmpty && snapshot.version == doc.current.version { return }
            after = snapshot
            step = Self.continues(edits, from: doc.current, to: snapshot)
                ? .edits(edits, before: doc.current, after: snapshot)
                : .full(snapshot)   // a batch was dropped or reordered: resynchronise
        case .resync(let snapshot):
            step = .full(snapshot)
            after = snapshot
        }
        guard after.utf8Count <= Self.maxFileBytes else { drop(uri); return }
        record(after, for: uri)
        enqueue(step, for: uri)
        startPump()
    }

    public func saved(uri: URL) async {
        guard !stopped, documents[uri] != nil else { return }
        queue.append(.save(uri: uri))
        startPump()
    }

    /// Pending opens and changes of the document are discarded; a queued save still goes out (when the server
    /// has the document) ahead of the didClose. A document the server never received sends nothing at all.
    public func close(uri: URL) async {
        guard documents[uri] != nil else { return }
        drop(uri)
    }

    /// After a server restart: open every tracked document with its current text. Idempotent for documents the
    /// current server already has.
    public func reopenAll() async {
        guard !stopped else { return }
        for (uri, _) in documents.sorted(by: { $0.key.absoluteString < $1.key.absoluteString }) {
            queue.append(.open(uri: uri))
        }
        startPump()
    }

    public func snapshot(for uri: URL, version: Int) -> CodeSnapshot? {
        documents[uri]?.history.last { Int($0.version) == version }
    }

    /// The position encoding the server negotiated (UTF-16 until it has answered).
    public func positionEncoding() async -> PositionEncoding {
        await server.capabilities?.positionEncoding ?? .utf16
    }

    /// Returns once the queue is empty and nothing is being sent (at once when it already is). The pump resumes the
    /// waiters when it finishes; nothing polls.
    /// Cancelling the waiting task ends the wait.
    public func waitUntilSent() async {
        guard !stopped, pumping || !queue.isEmpty else { return }
        let id = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                if Task.isCancelled || stopped { continuation.resume(); return }
                idleWaiters[id] = continuation
            }
        } onCancel: {
            Task { await self.cancelWaiter(id) }
        }
    }

    private func cancelWaiter(_ id: UUID) {
        idleWaiters.removeValue(forKey: id)?.resume()
    }

    /// The server was stopped for good (a reload replaced it, or the app is quitting): drops what is queued, ends the
    /// pump, which may be parked waiting for a server that will never start, and releases everything waiting for it.
    public func shutdown() {
        stopped = true
        queue.removeAll()
        documents.removeAll()
        pumpTask?.cancel()
        let waiters = idleWaiters
        idleWaiters = [:]
        for waiter in waiters.values { waiter.resume() }
    }

    /// Test observability: the change steps waiting in the queue for `uri`.
    func pendingStepCount(for uri: URL) -> Int {
        queue.reduce(0) { total, op in
            if case .change(let u, let steps) = op, u == uri { total + steps.count } else { total }
        }
    }
    /// Test observability: whether the pump task is alive.
    var isPumping: Bool { pumping }

    /// Test hook.
    func setPaused(_ value: Bool) {
        paused = value
        if !value { startPump() }
    }

    // MARK: - State

    private func record(_ snapshot: CodeSnapshot, for uri: URL) {
        guard var doc = documents[uri] else { return }
        doc.current = snapshot
        doc.history.append(snapshot)
        if doc.history.count > Self.historyLimit { doc.history.removeFirst(doc.history.count - Self.historyLimit) }
        documents[uri] = doc
    }

    private func drop(_ uri: URL) {
        documents[uri] = nil
        // Saves survive only for a document the server already has; otherwise nothing of it was ever sent.
        let serverHasIt = opened.contains(uri)
        queue.removeAll {
            switch $0 {
            case .open(let u), .change(let u, _): u == uri
            case .save(let u): u == uri && !serverHasIt
            case .close: false
            }
        }
        if serverHasIt || queue.contains(where: { if case .close(let u) = $0 { u == uri } else { false } }) {
            queue.append(.close(uri: uri))
        }
        startPump()
    }

    /// Whether `edits` is the unbroken run of events from `before` to `after`.
    private static func continues(_ edits: [CodeEdit], from before: CodeSnapshot, to after: CodeSnapshot) -> Bool {
        var expected = before.version
        for edit in edits {
            expected += 1
            if edit.version != expected { return false }
        }
        return expected == after.version
    }

    // MARK: - Queue

    private func enqueue(_ step: Step, for uri: URL) {
        var steps: [Step]
        if case .change(let u, let existing)? = queue.last, u == uri {
            steps = existing
            if case .full = step { steps = [step] } else { steps.append(step) }
            queue.removeLast()
        } else {
            steps = [step]
        }
        if steps.count > Self.maxPendingSteps, let current = documents[uri]?.current { steps = [.full(current)] }
        queue.append(.change(uri: uri, steps: steps))
    }

    private func startPump() {
        guard !pumping, !paused, !stopped else { return }
        pumping = true
        pumpTask = Task { await pump() }
    }

    /// The connection of a ready server. Waits while the server is stopped or starting (first start,
    /// restart); nil when it is `.failed` or `.notInstalled`.
    private func readyConnection() async -> JSONRPCConnection? {
        while true {
            if stopped || Task.isCancelled { return nil }
            switch await server.state {
            case .ready:
                if let rpc = try? await server.connection() { return rpc }
            case .failed, .notInstalled:
                return nil
            case .stopped, .starting:
                for await state in await server.stateChanges {
                    if state != .stopped && state != .starting { break }
                }
            }
        }
    }

    private func pump() async {
        while !queue.isEmpty && !paused {
            guard let rpc = await readyConnection() else { queue.removeAll(); break }
            if queue.isEmpty || paused { continue }   // the queue changed while waiting
            if lastConnection !== rpc {
                lastConnection = rpc
                opened.removeAll()   // a new server instance has seen nothing
            }
            await process(queue.removeFirst(), on: rpc)
        }
        pumping = false
        pumpTask = nil
        let waiters = idleWaiters
        idleWaiters = [:]
        for waiter in waiters.values { waiter.resume() }
    }

    private func process(_ op: Op, on rpc: JSONRPCConnection) async {
        switch op {
        case .open(let uri):
            await ensureOpen(uri, on: rpc)
        case .change(let uri, let steps):
            guard documents[uri] != nil else { return }
            if !opened.contains(uri) {
                // The open carries the current text, which already includes these changes.
                await ensureOpen(uri, on: rpc)
                return
            }
            let caps = await server.capabilities
            guard let message = Self.changeMessage(uri: uri, steps: steps, encoding: caps?.positionEncoding ?? .utf16,
                                                   sync: caps?.sync ?? .none) else { return }
            try? await rpc.notify("textDocument/didChange", message)
        case .save(let uri):
            if documents[uri] != nil { await ensureOpen(uri, on: rpc) }
            guard opened.contains(uri) else { return }
            try? await rpc.notify("textDocument/didSave", Self.identifier(uri))
        case .close(let uri):
            guard opened.remove(uri) != nil else { return }
            try? await rpc.notify("textDocument/didClose", Self.identifier(uri))
        }
    }

    /// Sends didOpen with the document's current text unless this server instance already has it. Everything
    /// queued for the document is now covered by that text.
    private func ensureOpen(_ uri: URL, on rpc: JSONRPCConnection) async {
        guard !opened.contains(uri), let doc = documents[uri] else { return }
        queue.removeAll { if case .change(let u, _) = $0 { u == uri } else { false } }
        opened.insert(uri)
        try? await rpc.notify("textDocument/didOpen", .object(["textDocument": .object([
            "uri": .string(uri.absoluteString),
            "languageId": .string(doc.languageID),
            "version": .number(Double(doc.current.version)),
            "text": .string(doc.current.text),
        ])]))
    }

    private static func identifier(_ uri: URL) -> JSONValue {
        .object(["textDocument": .object(["uri": .string(uri.absoluteString)])])
    }

    // MARK: - Messages

    private static func changeMessage(uri: URL, steps: [Step], encoding: PositionEncoding, sync: TextSyncKind) -> JSONValue? {
        guard sync != .none, let last = steps.last else { return nil }
        var changes: [JSONValue] = []
        if sync == .full {
            changes = [fullChange(steps)]
        } else {
            for step in steps {
                switch step {
                case .full(let snapshot): changes.append(.object(["text": .string(snapshot.text)]))
                case .edits(let edits, let before, let after):
                    changes.append(contentsOf: incrementalChanges(edits, before: before, after: after, encoding: encoding))
                }
            }
        }
        return .object([
            "textDocument": .object(["uri": .string(uri.absoluteString), "version": .number(Double(last.version))]),
            "contentChanges": .array(changes),
        ])
    }

    private static func fullChange(_ steps: [Step]) -> JSONValue {
        let snapshot: CodeSnapshot
        switch steps.last! {
        case .edits(_, _, let after): snapshot = after
        case .full(let s): snapshot = s
        }
        return .object(["text": .string(snapshot.text)])
    }

    private static func incrementalChanges(_ edits: [CodeEdit], before: CodeSnapshot, after: CodeSnapshot,
                                           encoding: PositionEncoding) -> [JSONValue] {
        func change(_ range: LSPRange, _ text: String) -> JSONValue {
            .object([
                "range": .object([
                    "start": .object(["line": .number(Double(range.start.line)), "character": .number(Double(range.start.character))]),
                    "end": .object(["line": .number(Double(range.end.line)), "character": .number(Double(range.end.character))]),
                ]),
                "text": .string(text),
            ])
        }
        if edits.count > scratchEditLimit { return [.object(["text": .string(after.text)])] }
        var result: [JSONValue] = []
        // The text before the current edit, replayed edit by edit for the later members of a batch.
        var scratch: [UInt8]? = edits.count > 1 ? before.utf8(in: 0..<before.utf8Count) : nil
        for (index, edit) in edits.enumerated() {
            let range: LSPRange
            if index == 0 {
                range = LSPRange(
                    start: Positions.lspPosition(utf8Offset: edit.range.lowerBound, in: before, encoding: encoding),
                    end: Positions.lspPosition(utf8Offset: edit.range.upperBound, in: before, encoding: encoding))
            } else {
                range = LSPRange(
                    start: point(edit.startPoint, offset: edit.range.lowerBound, scratch: scratch ?? [], encoding: encoding),
                    end: point(edit.oldEndPoint, offset: edit.range.upperBound, scratch: scratch ?? [], encoding: encoding))
            }
            result.append(change(range, edit.newText))
            scratch?.replaceSubrange(edit.range, with: Array(edit.newText.utf8))
        }
        return result
    }

    /// A position in the text before a later member of a batch, from the edit's own row and byte column.
    /// Like `Positions`, a position between a CR and its LF is the end of the line's content.
    private static func point(_ p: CodePoint, offset: Int, scratch: [UInt8], encoding: PositionEncoding) -> LSPPosition {
        var offset = min(offset, scratch.count)
        var column = p.column
        if offset > 0, offset < scratch.count, scratch[offset] == 0x0A, scratch[offset - 1] == 0x0D {
            offset -= 1
            column -= 1
        }
        let prefix = scratch[max(0, offset - column)..<offset]
        return LSPPosition(line: p.row, character: Positions.character(ofLinePrefix: prefix, encoding: encoding))
    }
}
