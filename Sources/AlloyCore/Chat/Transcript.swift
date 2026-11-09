import Foundation

public enum NoticeKind: String, Sendable { case compacted, interrupted, exited, error, warning, modelChanged, commandOutput, modeChanged, reset, history }

public struct ToolBlock: Sendable, Equatable {
    public enum Status: Sendable, Equatable { case running, succeeded, failed, denied, interrupted }
    public var toolUseID: String
    public var name: String
    public var kind: ToolKind
    public var summary: String
    public var status: Status
    public var resultText: String
    public var editIDs: [UUID]
    /// The tool call's full input.
    public var input: JSONValue
    public var startedAt: Date?
    public var endedAt: Date?
    /// The CLI's raw `tool_use_result`, once the call finished.
    public var result: JSONValue?

    public init(toolUseID: String, name: String, kind: ToolKind, summary: String,
                status: Status = .running, resultText: String = "", editIDs: [UUID] = [],
                input: JSONValue = .null, startedAt: Date? = nil, endedAt: Date? = nil, result: JSONValue? = nil) {
        self.toolUseID = toolUseID; self.name = name; self.kind = kind; self.summary = summary
        self.status = status; self.resultText = resultText; self.editIDs = editIDs
        self.input = input; self.startedAt = startedAt; self.endedAt = endedAt; self.result = result
    }
}

/// Where an interactive card (question, plan) stands.
public enum CardState: Sendable, Equatable { case pending, answered, sentBack, cancelled }

/// An `AskUserQuestion` prompt, shown as a card instead of a permission row.
public struct QuestionBlock: Sendable, Equatable {
    public struct Question: Sendable, Equatable {
        public struct Option: Sendable, Equatable {
            public var label: String
            public var description: String
            public init(label: String, description: String) { self.label = label; self.description = description }
        }
        public var question: String
        public var header: String
        public var options: [Option]
        public var multiSelect: Bool
        public init(question: String, header: String, options: [Option], multiSelect: Bool) {
            self.question = question; self.header = header; self.options = options; self.multiSelect = multiSelect
        }
    }

    public var requestID: String
    public var toolUseID: String?
    public var questions: [Question]
    public var state: CardState
    public var answers: [String: String]

    public init(requestID: String, toolUseID: String?, questions: [Question],
                state: CardState = .pending, answers: [String: String] = [:]) {
        self.requestID = requestID; self.toolUseID = toolUseID; self.questions = questions
        self.state = state; self.answers = answers
    }

    init(requestID: String, toolUseID: String?, input: JSONValue) {
        let qs = (input["questions"]?.arrayValue ?? []).map { q in
            Question(question: q["question"]?.stringValue ?? "",
                     header: q["header"]?.stringValue ?? "",
                     options: (q["options"]?.arrayValue ?? []).map {
                         Question.Option(label: $0["label"]?.stringValue ?? "",
                                         description: $0["description"]?.stringValue ?? "")
                     },
                     multiSelect: q["multiSelect"]?.boolValue ?? false)
        }
        self.init(requestID: requestID, toolUseID: toolUseID, questions: qs)
    }
}

/// An `ExitPlanMode` proposal, shown as a card instead of a permission row.
public struct PlanBlock: Sendable, Equatable {
    public var requestID: String
    public var toolUseID: String?
    public var plan: String
    public var planFilePath: String?
    public var state: CardState
    public var feedback: String?

    public init(requestID: String, toolUseID: String?, plan: String, planFilePath: String?,
                state: CardState = .pending, feedback: String? = nil) {
        self.requestID = requestID; self.toolUseID = toolUseID; self.plan = plan
        self.planFilePath = planFilePath; self.state = state; self.feedback = feedback
    }
}

/// Whether a user message reached the CLI's turn, or still waits behind the running one.
public enum UserState: Sendable, Equatable { case sent, queued(Priority) }

public struct PermissionBlock: Sendable, Equatable {
    public enum State: Sendable, Equatable { case pending, allowed, denied, cancelled }
    public var requestID: String
    public var toolName: String
    public var summary: String
    public var input: JSONValue
    public var state: State
    /// The tool call this prompt guards, when the CLI said so.
    public var toolUseID: String?

    public init(requestID: String, toolName: String, summary: String, input: JSONValue,
                state: State = .pending, toolUseID: String? = nil) {
        self.requestID = requestID; self.toolName = toolName; self.summary = summary
        self.input = input; self.state = state; self.toolUseID = toolUseID
    }
}

public enum ChatBlock: Identifiable, Sendable, Equatable {
    case user(id: UUID, text: String, imageCount: Int, state: UserState)
    case assistantText(id: String, text: String)
    case thinking(id: String, text: String, estimatedTokens: Int)
    case tool(ToolBlock)
    case permission(PermissionBlock)
    case question(QuestionBlock)
    case plan(PlanBlock)
    case notice(id: UUID, kind: NoticeKind, text: String)
    /// A message between sessions: `.from` in the chat of the one that received it, `.to` in the sender's.
    /// `peerID` is the other session (nil for Alloy itself, or when the peer is only known by name from history).
    case sessionMessage(id: UUID, direction: SessionMessageDirection, peer: String, peerID: UUID?, text: String)

    public var id: String {
        switch self {
        case .user(let id, _, _, _): return id.uuidString
        case .assistantText(let id, _): return id
        case .thinking(let id, _, _): return id
        case .tool(let t): return t.toolUseID
        case .permission(let p): return "perm-\(p.requestID)"
        case .question(let q): return "q-\(q.requestID)"
        case .plan(let p): return "plan-\(p.requestID)"
        case .notice(let id, _, _): return id.uuidString
        case .sessionMessage(let id, _, _, _, _): return "session-message-\(id.uuidString)"
        }
    }
}

/// `.from` / `.to`: another session, by name. `.system`: Alloy itself ("From Alloy"), never a session, so it takes
/// no session colour; a session cannot pass for it because its wire form is one no session name can produce.
public enum SessionMessageDirection: Sendable, Equatable { case from, to, system }

/// Reduces the inbound message stream into display blocks.
///
/// Block ids are stable: a text/thinking block gets its id "m<seq>#<index>" when it is created
/// (at `blockStart`, or at the `assistant` message when nothing streamed) and is never renamed.
/// `seq` is a per-transcript counter that advances when a new assistant message begins: a
/// `blockStart` whose index does not exceed the previous one, the first block of an unseen
/// messageID that no stream has claimed, or the first block after a `.result`. The Nth
/// `assistantBlock` of a message (N = blocks already seen for that messageID, matching the content
/// index) adopts the streamed block at index N when the kinds match, replacing its text with the
/// final text; otherwise it appends. `.result` (and `finalizeStreaming()`) drops empty streamed
/// blocks and closes the message. `pendingEchoes` (texts from `appendUser` awaiting their CLI echo)
/// is cleared at each `.result`, so an unmatched echo never suppresses a later identical prompt.
public struct Transcript: Sendable, Equatable {
    public private(set) var blocks: [ChatBlock] = []
    public let projectRoot: URL

    private enum StreamKind { case text, thinking }
    private struct Open: Equatable { var id: String; var kind: StreamKind }
    private var streaming: [Int: Open] = [:]   // content index -> open streamed block
    private var seq = 0
    private var messageOpen = false
    private var seqClaimed = false
    private var lastStartIndex = -1
    private var messageSeq: [String: Int] = [:]         // messageID -> seq
    private var seenCounts: [String: Int] = [:]         // messageID -> blocks seen
    private struct PendingEcho: Equatable { var id: UUID; var text: String; var queued: Bool; var next: Bool }
    private var pendingEchoes: [PendingEcho] = []
    /// Texts of matched `.next` messages whose CLI re-echo (a second, differently-id'd replay at the
    /// turn boundary) is still expected. Consume-once; cleared at `.result`.
    private var expectedReechoes: [String: Int] = [:]
    private var deniedToolIDs: Set<String> = []
    private var cancelledToolIDs: Set<String> = []      // permission withdrawn (interrupt) before a result
    private var currentThinkingID: String?
    private var carriedThinkingTokens = 0
    private var anonymousTools = 0

    public init(projectRoot: URL) {
        self.projectRoot = projectRoot
    }

    /// Adds a message the user just sent. With `queued`, it shows as waiting until the CLI echoes it.
    public mutating func appendUser(text: String, imageCount: Int = 0, id: UUID, queued: Priority? = nil) {
        pendingEchoes.append(PendingEcho(id: id, text: text, queued: queued != nil, next: queued == .next))
        push(.user(id: id, text: text, imageCount: imageCount, state: queued.map { .queued($0) } ?? .sent))
    }

    /// Adds a message between sessions. `id` is the uuid the message goes out under, so its CLI echo lands here
    /// instead of becoming a user bubble. `queued` keeps the echo expected across a running turn, as for a user message.
    public mutating func appendSessionMessage(id: UUID, direction: SessionMessageDirection, peer: String, peerID: UUID?,
                                              text: String, queued: Priority? = nil, wire: String? = nil) {
        if let wire { pendingEchoes.append(PendingEcho(id: id, text: wire, queued: queued != nil, next: queued == .next)) }
        let block = ChatBlock.sessionMessage(id: id, direction: direction, peer: peer, peerID: peerID, text: text)
        // The sender's row belongs right after the send_message call that produced it. The "To" row is live-only:
        // the transcript file records what the sender's model said (the tool call), not Alloy's row, so a replay
        // shows no "To" row. "From" rows survive replay: the receiver's file holds the wire text.
        if direction == .to, let i = blocks.lastIndex(where: {
            if case .tool(let t) = $0 { return t.name.hasSuffix("send_message") && t.status == .running } else { return false }
        }) {
            blocks.insert(block, at: i + 1)
            reindex()
        } else {
            push(block)
        }
    }

    /// Puts earlier history (replayed from the CLI's transcript file) in front of what is already shown.
    public mutating func prepend(history: [ChatBlock]) {
        blocks.insert(contentsOf: history, at: 0)
        reindex()
    }

    /// Ends a replay: tools that never got a result were cut off, so they show as interrupted, not running.
    public mutating func finishReplay() {
        finalizeStreaming()
        for i in blocks.indices {
            if case .tool(var t) = blocks[i], t.status == .running { t.status = .interrupted; blocks[i] = .tool(t) }
        }
    }

    public mutating func attach(editIDs: [UUID], toToolUseID id: String) {
        mutateTool(id) { $0.editIDs.append(contentsOf: editIDs) }
    }

    public mutating func resolvePermission(requestID: String, allowed: Bool) {
        guard let i = permissionIndex(requestID) else { return }
        guard case .permission(var p) = blocks[i], p.state == .pending else { return }
        p.state = allowed ? .allowed : .denied
        blocks[i] = .permission(p)
        if !allowed, let tid = p.toolUseID {
            deniedToolIDs.insert(tid)
            mutateTool(tid) { if $0.status == .running { $0.status = .denied } }
        }
    }

    public mutating func apply(_ message: InboundMessage) { apply(message, now: Date()) }

    public mutating func resolveQuestion(requestID: String, answers: [String: String]) {
        guard let i = indexOf("q-\(requestID)"), case .question(var q) = blocks[i], q.state == .pending else { return }
        q.state = .answered
        q.answers = answers
        blocks[i] = .question(q)
    }

    /// Approving finishes the card; sending it back keeps the feedback and denies the `ExitPlanMode` call.
    public mutating func resolvePlan(requestID: String, approved: Bool, feedback: String?) {
        guard let i = indexOf("plan-\(requestID)"), case .plan(var p) = blocks[i], p.state == .pending else { return }
        p.state = approved ? .answered : .sentBack
        p.feedback = approved ? nil : feedback
        blocks[i] = .plan(p)
        if !approved, let tid = p.toolUseID {
            deniedToolIDs.insert(tid)
            mutateTool(tid) { if $0.status == .running { $0.status = .denied } }
        }
    }

    /// `now` stamps tool start and end; a replay passes the record's own time, or nil when the record has none.
    public mutating func apply(_ message: InboundMessage, now: Date?) {
        switch message {
        case .delta(let d): applyDelta(d)
        case .assistantBlock(let mid, let block): applyAssistant(messageID: mid, block: block, now: now)
        case .toolResult(let r):
            let denied = deniedToolIDs.contains(r.toolUseID)
            let cancelled = cancelledToolIDs.contains(r.toolUseID)
            // On failure the CLI's top-level plain string ("Error: ...") is the fuller message.
            var text = r.text
            if r.isError, case .message(let m) = r.result, !m.isEmpty { text = m }
            let root = projectRoot
            mutateTool(r.toolUseID) {
                $0.endedAt = now
                $0.summary = ToolSummary.line(toolName: $0.name, input: $0.input, projectRoot: root, result: r.raw)
                $0.result = r.raw
                $0.resultText = text
                $0.status = !r.isError ? .succeeded : denied ? .denied : cancelled ? .interrupted : .failed
            }
        case .userEcho(let text, let imageCount, let uuid, let isReplay):
            let echoID = uuid.flatMap { UUID(uuidString: $0) }
            if let shown = Self.commandEcho(text) {
                // Slash-command output (/compact, /cost) is the CLI talking, never a user bubble.
                if !shown.isEmpty { push(.notice(id: UUID(), kind: .commandOutput, text: shown)) }
            } else if let i = pendingEchoes.firstIndex(where: { $0.id == echoID }) ?? pendingEchoes.firstIndex(where: { $0.text == text }) {
                let matched = pendingEchoes.remove(at: i)
                markSent(matched.id)
                if matched.next { expectedReechoes[matched.text, default: 0] += 1 }
            } else if isReplay, let n = expectedReechoes[text], n > 0 {
                expectedReechoes[text] = n == 1 ? nil : n - 1
            } else if let echoID, indexOf(echoID.uuidString) != nil || indexOf("session-message-\(echoID.uuidString)") != nil {
                break
            } else if let wire = SessionMessageWire.parse(text) {
                // A message from another session (history, or a resumed process replaying it).
                // With a uuid, the id check above already dropped a repeat; only a uuid-less replay falls back to
                // comparing with the last row.
                let direction: SessionMessageDirection = wire.sender == nil ? .system : .from
                let peer = wire.sender ?? Messages.systemSender
                if isReplay, echoID == nil, case .sessionMessage(_, direction, peer, _, wire.body)? = blocks.last(where: {
                    if case .sessionMessage(_, .from, _, _, _) = $0 { return true }
                    if case .sessionMessage(_, .system, _, _, _) = $0 { return true }
                    return false
                }) { break }
                push(.sessionMessage(id: echoID ?? UUID(), direction: direction, peer: peer, peerID: nil, text: wire.body))
            } else if isReplay, case .user(_, let last, _, _)? = blocks.last(where: { if case .user = $0 { return true } else { return false } }), last == text {
                break
            } else {
                push(.user(id: echoID ?? UUID(), text: text, imageCount: imageCount, state: .sent))
            }
        case .result(let r):
            finalizeStreaming()
            // Messages still queued behind this turn keep waiting for their own echo.
            pendingEchoes.removeAll { !$0.queued }
            expectedReechoes.removeAll()
            if r.terminalReason == "aborted_tools" || r.terminalReason == "aborted_streaming" { interrupt() }
            else if r.isError {
                for i in blocks.indices {
                    if case .tool(var t) = blocks[i], t.status == .running { t.status = .failed; blocks[i] = .tool(t) }
                }
                push(.notice(id: UUID(), kind: .error, text: Self.errorText(r.subtype)))
            }
        case .controlRequest(let req):
            if case .canUseTool(let name, let input, let desc, let tid, _) = req.kind {
                if name == "AskUserQuestion" {
                    push(.question(QuestionBlock(requestID: req.requestID, toolUseID: tid, input: input)))
                    return
                }
                if name == "ExitPlanMode" {
                    push(.plan(PlanBlock(requestID: req.requestID, toolUseID: tid,
                        plan: input["plan"]?.stringValue ?? "", planFilePath: input["planFilePath"]?.stringValue)))
                    return
                }
                let summary = ToolSummary.line(toolName: name, input: input, projectRoot: projectRoot)
                push(.permission(PermissionBlock(requestID: req.requestID, toolName: name,
                    summary: summary.isEmpty ? (desc ?? name) : summary, input: input, toolUseID: tid)))
            }
        case .controlCancel(let rid):
            if let i = permissionIndex(rid), case .permission(var p) = blocks[i], p.state == .pending {
                p.state = .cancelled
                blocks[i] = .permission(p)
                if let tid = p.toolUseID { cancelledToolIDs.insert(tid) }
            } else if let i = indexOf("q-\(rid)"), case .question(var q) = blocks[i], q.state == .pending {
                q.state = .cancelled
                blocks[i] = .question(q)
                if let tid = q.toolUseID { cancelledToolIDs.insert(tid) }
            } else if let i = indexOf("plan-\(rid)"), case .plan(var p) = blocks[i], p.state == .pending {
                p.state = .cancelled
                blocks[i] = .plan(p)
                if let tid = p.toolUseID { cancelledToolIDs.insert(tid) }
            }
        case .permissionDenied(_, let tid, _):
            deniedToolIDs.insert(tid)
            mutateTool(tid) { if $0.status == .running { $0.status = .denied } }
        case .compactBoundary(let pre, let post):
            func f(_ n: Int?) -> String { n.map(String.init) ?? "?" }
            push(.notice(id: UUID(), kind: .compacted,
                                  text: "Conversation compacted (\(f(pre)) to \(f(post)) tokens)"))
        case .compactSummary:
            // The boundary record normally comes first and has already said so.
            if case .notice(_, .compacted, _)? = blocks.last { break }
            push(.notice(id: UUID(), kind: .compacted, text: "Conversation compacted"))
        case .thinkingTokens(let n): addThinkingTokens(n)
        case .localCommandOutput(let text):
            if !text.isEmpty { push(.notice(id: UUID(), kind: .commandOutput, text: text)) }
        // Consumed by later Plan 3 tasks (workspace/session layers); the transcript has nothing to show.
        case .conversationReset:
            push(.notice(id: UUID(), kind: .reset, text: "Conversation cleared"))
        case .commandsChanged, .statusChanged, .controlResponse: break
        case .systemInit, .ignored, .unknown: break
        }
    }

    /// Marks every tool call still running as interrupted (the process that ran it is gone).
    public mutating func interruptRunningTools() {
        for i in blocks.indices {
            if case .tool(var t) = blocks[i], t.status == .running { t.status = .interrupted; blocks[i] = .tool(t) }
        }
    }

    /// Marks every pending permission prompt cancelled (the process that asked is gone).
    public mutating func cancelPendingPermissions() {
        cancelPendingPrompts()
    }

    public mutating func appendNotice(kind: NoticeKind, text: String) {
        push(.notice(id: UUID(), kind: kind, text: text))
    }

    /// Ends the open assistant message: empty streamed text/thinking blocks are removed, non-empty
    /// ones stay as final. Called on `.result`; call it too when the process exits.
    public mutating func finalizeStreaming() {
        for (_, entry) in streaming {
            guard let i = indexOf(entry.id) else { continue }
            switch blocks[i] {
            case .assistantText(_, let t) where t.isEmpty: blocks.remove(at: i); reindex()
            case .thinking(_, let t, _) where t.isEmpty: blocks.remove(at: i); reindex()
            default: break
            }
        }
        streaming.removeAll()
        currentThinkingID = nil
        messageOpen = false
        seqClaimed = false
        lastStartIndex = -1
    }

    // MARK: - Private

    /// What an error result says, in words.
    static func errorText(_ subtype: String) -> String {
        switch subtype {
        case "error_during_execution": "Claude stopped with an error"
        case "error_max_turns": "Reached the turn limit"
        default: "Claude reported an error (\(subtype))"
        }
    }

    /// The inner text of a `<local-command-stdout>` or `<command-name>` echo; nil when `text` is neither.
    static func commandEcho(_ text: String) -> String? {
        for tag in ["local-command-stdout", "command-name"] {
            guard let open = text.range(of: "<\(tag)>") else { continue }
            let rest = text[open.upperBound...]
            let inner = rest.range(of: "</\(tag)>").map { rest[..<$0.lowerBound] } ?? rest
            return inner.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return nil
    }

    private mutating func cancelPendingPrompts() {
        for i in blocks.indices {
            switch blocks[i] {
            case .permission(var p) where p.state == .pending:
                p.state = .cancelled; blocks[i] = .permission(p)
            case .question(var q) where q.state == .pending:
                q.state = .cancelled; blocks[i] = .question(q)
            case .plan(var p) where p.state == .pending:
                p.state = .cancelled; blocks[i] = .plan(p)
            default: break
            }
        }
    }

    /// The process is gone, so messages still waiting behind a turn will never be echoed: show them as sent, forget
    /// their pending echoes and say once how many were lost.
    public mutating func abandonQueued() {
        var lost = 0
        for i in blocks.indices {
            if case .user(let id, let text, let n, .queued) = blocks[i] {
                blocks[i] = .user(id: id, text: text, imageCount: n, state: .sent)
                lost += 1
            }
        }
        pendingEchoes.removeAll { $0.queued }
        expectedReechoes.removeAll()
        guard lost > 0 else { return }
        push(.notice(id: UUID(), kind: .error,
                     text: lost == 1 ? "1 queued message was not delivered" : "\(lost) queued messages were not delivered"))
    }

    private mutating func markSent(_ id: UUID) {
        guard let i = indexOf(id.uuidString), case .user(let uid, let text, let n, _) = blocks[i] else { return }
        blocks[i] = .user(id: uid, text: text, imageCount: n, state: .sent)
    }

    private mutating func interrupt() {
        for i in blocks.indices {
            if case .tool(var t) = blocks[i], t.status == .running { t.status = .interrupted; blocks[i] = .tool(t) }
        }
        cancelPendingPrompts()
        push(.notice(id: UUID(), kind: .interrupted, text: "Interrupted"))
    }

    private mutating func applyDelta(_ d: StreamDelta) {
        switch d {
        case .blockStart(let index, let kind):
            if !messageOpen || index <= lastStartIndex {
                streaming.removeAll()
                seq += 1; messageOpen = true; seqClaimed = false
            }
            lastStartIndex = index
            let id = "m\(seq)#\(index)"
            switch kind {
            case "text":
                streaming[index] = Open(id: id, kind: .text)
                push(.assistantText(id: id, text: ""))
            case "thinking":
                streaming[index] = Open(id: id, kind: .thinking); currentThinkingID = id
                push(.thinking(id: id, text: "", estimatedTokens: carriedThinkingTokens))
                carriedThinkingTokens = 0
            default: break
            }
        case .text(let index, let s):
            guard let e = streaming[index], e.kind == .text, let i = indexOf(e.id) else { return }
            if case .assistantText(_, let t) = blocks[i] { blocks[i] = .assistantText(id: e.id, text: t + s) }
        case .thinking(let index, let s, let est):
            guard let e = streaming[index], e.kind == .thinking, let i = indexOf(e.id) else { return }
            if case .thinking(_, let t, let n) = blocks[i] {
                blocks[i] = .thinking(id: e.id, text: t + s, estimatedTokens: n + (est ?? 0))
            }
        case .toolInput: break
        case .blockStop: break
        }
    }

    private mutating func applyAssistant(messageID: String, block: ContentBlock, now: Date?) {
        if messageSeq[messageID] == nil {
            if messageOpen && !seqClaimed {
                messageSeq[messageID] = seq
            } else {
                seq += 1; messageSeq[messageID] = seq
                messageOpen = true; lastStartIndex = Int.max
            }
            seqClaimed = true
        }
        let n = seenCounts[messageID, default: 0]
        seenCounts[messageID] = n + 1
        let finalID = "m\(messageSeq[messageID]!)#\(n)"
        var existing: Int?
        if let e = streaming[n], e.id == finalID {
            switch (block, e.kind) {
            case (.text, .text), (.thinking, .thinking):
                existing = indexOf(e.id); streaming[n] = nil
            default: break
            }
        }
        switch block {
        case .text(let text):
            if let i = existing { blocks[i] = .assistantText(id: finalID, text: text) }
            else { push(.assistantText(id: uniqueID(finalID), text: text)) }
        case .thinking(let text):
            if let i = existing, case .thinking(_, let old, let tokens) = blocks[i] {
                blocks[i] = .thinking(id: finalID, text: text.isEmpty ? old : text, estimatedTokens: tokens)
                currentThinkingID = finalID
            } else {
                let id = uniqueID(finalID)
                push(.thinking(id: id, text: text, estimatedTokens: carriedThinkingTokens))
                carriedThinkingTokens = 0
                currentThinkingID = id
            }
        case .toolUse(let rawID, let name, let input, _):
            // An empty id would collide with every other empty one: give it a unique fallback.
            var id = rawID
            if id.isEmpty { anonymousTools += 1; id = "tool-anon-\(anonymousTools)" }
            guard indexOf(id) == nil else { return }
            let denied = deniedToolIDs.contains(id)
            push(.tool(ToolBlock(
                toolUseID: id, name: name, kind: ToolKind.classify(name),
                summary: ToolSummary.line(toolName: name, input: input, projectRoot: projectRoot),
                status: denied ? .denied : .running, input: input, startedAt: now)))
        }
    }

    /// Kind-mismatch fallback: never collide with an existing id.
    private func uniqueID(_ id: String) -> String { indexOf(id) == nil ? id : id + "-r" }

    private mutating func addThinkingTokens(_ n: Int) {
        if let id = currentThinkingID, let i = indexOf(id), case .thinking(let bid, let t, let old) = blocks[i] {
            blocks[i] = .thinking(id: bid, text: t, estimatedTokens: old + n)
        } else {
            carriedThinkingTokens += n
        }
    }

    /// id -> index of the last block with that id. Kept in step with `blocks` so lookups never rescan.
    private var idIndex: [String: Int] = [:]

    private func indexOf(_ id: String) -> Int? { idIndex[id] }

    private mutating func push(_ block: ChatBlock) {
        idIndex[block.id] = blocks.count
        blocks.append(block)
    }

    private mutating func reindex() {
        idIndex.removeAll(keepingCapacity: true)
        for (i, b) in blocks.enumerated() { idIndex[b.id] = i }
    }

    private func permissionIndex(_ requestID: String) -> Int? { indexOf("perm-\(requestID)") }

    private mutating func mutateTool(_ id: String, _ body: (inout ToolBlock) -> Void) {
        guard let i = indexOf(id), case .tool(var t) = blocks[i] else { return }
        body(&t)
        blocks[i] = .tool(t)
    }
}
