import Foundation
import Observation

public enum SessionStatus: Equatable, Sendable {
    /// Restored from disk; no process runs until the first send or an explicit wake.
    case dormant
    case starting, idle, working, awaitingPermission
    case exited(status: Int32, message: String)
    case failedToLaunch(String)
}

@MainActor @Observable
public final class Session: Identifiable {
    public let id: UUID
    public var name: String
    public let colorIndex: Int
    public internal(set) var status: SessionStatus = .starting
    public internal(set) var transcript: Transcript
    /// Cost across all of this session's processes. `total_cost_usd` is the running total of the current
    /// process (the compact fixture rises from 0.0015 to 0.0025 on a zero-usage turn), so this is the total of
    /// the earlier processes plus the latest result's. The live smoke run will confirm it.
    public internal(set) var costUSD: Double = 0
    private var costBase: Double = 0
    /// Reads this session started that another read (its own earlier one, or another session's) already covered.
    public internal(set) var redundantReads = 0
    public internal(set) var inputTokens: Int = 0
    public internal(set) var outputTokens: Int = 0
    /// Total tokens processed: input + cache creation + cache read + output, summed per `result` (the sidebar's "tok").
    public internal(set) var totalTokens: Int = 0
    public internal(set) var model: String?
    public internal(set) var permissionMode: String?
    /// True once the CLI has a conversation for this id (first init or result), so `--resume` is valid.
    public internal(set) var hasConversation: Bool
    /// The id of the CLI conversation (the transcript file's name). Starts as `id`; every `system/init` names it,
    /// which is how `/clear` moves a session to a new conversation. `--resume` uses this.
    public internal(set) var cliSessionID: String
    /// For a fork that has not yet had its first turn: the conversation it was forked from. `--resume` of this id
    /// with `--fork-session` is how the process starts; the fork's own id arrives with its first `system/init`,
    /// which clears this.
    public internal(set) var forkSource: String?
    /// With `forkSource`: the last message of the source when the fork was made (`--resume-session-at`), so every
    /// launch of the unsent fork starts from that point however far the source has moved on. Cleared with `forkSource`.
    public internal(set) var forkPoint: String?
    /// Slash commands the user may run, without the terminal-only ones.
    public internal(set) var slashCommands: [SlashCommandInfo] = []
    /// TUI-only commands (`/doctor`, ...) hidden from `slashCommands`.
    public internal(set) var terminalOnlyCommands: Set<String> = []
    /// Set by `/model` with no argument; the composer opens the model menu and resets it to false.
    /// Publicly settable because the composer (AlloyKit) resets it after opening the menu.
    public var requestModelPicker = false
    private var allCommands: [SlashCommandInfo] = []

    /// Ids of this session's user messages that still wait behind a running turn.
    public var queued: [UUID] {
        transcript.blocks.compactMap { if case .user(let id, _, _, .queued) = $0 { return id } else { return nil } }
    }

    init(id: UUID, name: String, colorIndex: Int, projectRoot: URL, hasConversation: Bool = false,
         cliSessionID: String? = nil, model: String? = nil, permissionMode: String? = nil, forkSource: String? = nil,
         forkPoint: String? = nil) {
        self.forkSource = forkSource
        self.forkPoint = forkPoint
        self.hasConversation = hasConversation
        self.cliSessionID = cliSessionID ?? id.uuidString.lowercased()
        self.model = model; self.permissionMode = permissionMode
        self.id = id; self.name = name; self.colorIndex = colorIndex
        self.transcript = Transcript(projectRoot: projectRoot)
    }

    /// A new process starts counting its own total from zero; what has accrued so far becomes the base.
    func beginProcess() { costBase = costUSD }

    /// True while a permission prompt, question card or plan card waits for an answer.
    var hasPendingPermission: Bool {
        transcript.blocks.contains {
            switch $0 {
            case .permission(let p): p.state == .pending
            case .question(let q): q.state == .pending
            case .plan(let p): p.state == .pending
            default: false
            }
        }
    }

    /// Commands Alloy handles itself, offered in `/` autocomplete beside the CLI's.
    static func withLocalCommands(_ commands: [SlashCommandInfo]) -> [SlashCommandInfo] {
        // Nothing is offered until the CLI has given its list (an empty list means "not known yet").
        guard !commands.isEmpty, !commands.contains(where: { $0.name == "fork" }) else { return commands }
        return commands + [SlashCommandInfo(name: "fork", description: "Start a new session from this conversation",
                                            argumentHint: "[name]")]
    }

    /// A saved list for a session whose process has not started; the CLI's next list replaces it.
    func restoreCommands(_ commands: [SlashCommandInfo]) {
        allCommands = commands
        slashCommands = Self.withLocalCommands(commands)
    }

    func setCommands(_ commands: [SlashCommandInfo]) {
        allCommands = commands
        slashCommands = Self.withLocalCommands(commands.filter { !terminalOnlyCommands.contains($0.name) })
    }

    /// Applies one process event to the transcript and status.
    func handle(_ event: ProcessEvent) {
        switch event {
        case .exited(let code, let tail):
            transcript.finalizeStreaming()
            transcript.interruptRunningTools()
            transcript.cancelPendingPermissions()
            let trimmed = tail.trimmingCharacters(in: .whitespacesAndNewlines)
            let text = trimmed.isEmpty ? "Claude exited (status \(code))" : "Claude exited (status \(code)): \(trimmed)"
            transcript.appendNotice(kind: .exited, text: text)
            transcript.abandonQueued()
            status = .exited(status: code, message: trimmed.isEmpty ? "Claude exited (status \(code))" : trimmed)
        case .message(let m):
            transcript.apply(m)
            switch m {
            case .systemInit(let i):
                model = i.model; permissionMode = i.permissionMode; status = .working
                if !i.sessionID.isEmpty { hasConversation = true; cliSessionID = i.sessionID; forkSource = nil; forkPoint = nil }
                terminalOnlyCommands = Set(i.terminalSlashCommands)
                setCommands(allCommands)
            case .commandsChanged(let commands):
                setCommands(commands)
            case .statusChanged(let mode):
                if let mode, mode != permissionMode {
                    permissionMode = mode
                    transcript.appendNotice(kind: .modeChanged,
                                            text: "Mode: \(PermissionMode(rawValue: mode)?.displayName ?? mode)")
                }
            case .assistantBlock:
                status = .working
            case .controlRequest(let r):
                if case .canUseTool = r.kind { status = .awaitingPermission }
            case .controlCancel:
                if status == .awaitingPermission, !hasPendingPermission { status = .working }
            case .result(let r):
                costUSD = costBase + r.costUSD; inputTokens += r.inputTokens; outputTokens += r.outputTokens
                totalTokens += r.inputTokens + r.cacheCreationTokens + r.cacheReadTokens + r.outputTokens
                status = .idle; hasConversation = true
            default: break
            }
        }
    }
}
