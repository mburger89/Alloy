import Foundation
import MetalUICodeBuffer
import Observation

private enum PendingControlKind { case initialize, setModel(String), setMode(String) }

public typealias TransportFactory = @Sendable (LaunchConfiguration) -> any SessionTransport

struct SessionRecord: Codable {
    var id: UUID
    var name: String
    var colorIndex: Int
    var hasConversation: Bool = false
    var cliSessionID: String?
    var model: String?
    var permissionMode: String?
    /// The last command list the CLI gave, so `/` suggests on a restored session before its process starts.
    var slashCommands: [SlashCommandInfo]?
    /// A fork's source conversation until the fork has its own id (see `Session.forkSource`).
    var forkSource: String?
    /// The source's last message when the fork was made (`Session.forkPoint`).
    var forkPoint: String?
    /// What the session is for; nil (a record from before themes) means coding.
    var purpose: SessionPurpose?

    init(id: UUID, name: String, colorIndex: Int, hasConversation: Bool,
         cliSessionID: String? = nil, model: String? = nil, permissionMode: String? = nil,
         slashCommands: [SlashCommandInfo]? = nil, forkSource: String? = nil, forkPoint: String? = nil,
         purpose: SessionPurpose? = nil) {
        self.purpose = purpose
        self.forkSource = forkSource
        self.forkPoint = forkPoint
        self.id = id; self.name = name; self.colorIndex = colorIndex; self.hasConversation = hasConversation
        self.cliSessionID = cliSessionID; self.model = model; self.permissionMode = permissionMode
        self.slashCommands = slashCommands
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        colorIndex = try c.decode(Int.self, forKey: .colorIndex)
        hasConversation = try c.decodeIfPresent(Bool.self, forKey: .hasConversation) ?? false
        cliSessionID = try c.decodeIfPresent(String.self, forKey: .cliSessionID)
        model = try c.decodeIfPresent(String.self, forKey: .model)
        permissionMode = try c.decodeIfPresent(String.self, forKey: .permissionMode)
        slashCommands = try c.decodeIfPresent([SlashCommandInfo].self, forKey: .slashCommands)
        forkSource = try c.decodeIfPresent(String.self, forKey: .forkSource)
        forkPoint = try c.decodeIfPresent(String.self, forKey: .forkPoint)
        purpose = try c.decodeIfPresent(SessionPurpose.self, forKey: .purpose)
    }
}

@MainActor @Observable
public final class Workspace {
    public let projectRoot: URL
    /// How long the shared knowledge pool waits for another connection's write lock (tests shorten it).
    let poolBusyTimeoutMS: Int
    /// The project's files for `@file` and quick open; refreshed on demand.
    public let fileIndex: FileIndex
    public private(set) var sessions: [Session] = []
    public private(set) var ledger: ProjectLedger
    public var selectedSessionID: Session.ID? {
        didSet {
            guard let id = selectedSessionID, id != oldValue, historyPending.contains(id) else { return }
            Task { await loadHistory(id) }
        }
    }
    /// The project-relative path shown in the file panel (set by a click on a changed file or by the command line).
    /// Alias of `activeTab` that keeps Plan 1 call sites: setting a path opens (and activates) it.
    public var openFilePath: String? {
        get { activeTab }
        set {
            guard let path = newValue else { activeTab = nil; return }
            if !tabs.contains(path) { tabs.append(path) }
            activeTab = path
            track { [weak self] in await self?.open(path) }
        }
    }
    /// Open files in open order.
    public private(set) var tabs: [String] = []
    /// The tab the code panel shows.
    public var activeTab: String? {
        didSet {
            // Leaving a tab saves it.
            guard let old = oldValue, old != activeTab, documents[old]?.isDirty == true else { return }
            track { [weak self] in try? await self?.save(old) }
        }
    }
    /// True while the code panel holds keyboard focus (the panel reports it); following edits never interrupts it.
    public var codePanelFocused = false
    /// Why a tab has no document ("Binary file", unreadable, outside the project).
    public internal(set) var tabMessages: [String: String] = [:]
    var documents: [String: EditorDocument] = [:]
    /// How many times a save has written a file (for tests).
    @ObservationIgnored public private(set) var writeCount = 0
    /// Saves in flight, by path; a second save of the same file waits for the first.
    @ObservationIgnored var saving: [String: Task<Void, Error>] = [:]
    /// Counts finished saves per path, so a read can tell that a save finished while it ran.
    @ObservationIgnored private var saveEpoch: [String: Int] = [:]
    @ObservationIgnored private var ledgerWrite: Task<Void, Never>?
    /// The newest compaction-generations write (`generations.json`).
    @ObservationIgnored var generationsWrite: Task<Void, Never>?
    @ObservationIgnored var toldWrite: Task<Void, Never>?
    /// Session-written notes on files and topics (Plan 5a).
    public internal(set) var notes = NotesStore()
    /// Lookups that found something plus reads the notes served: answers the notes gave instead of a file read.
    public internal(set) var notesServed = 0
    /// The three shared-notes tools the local server offers.
    @ObservationIgnored public private(set) var notesTools: [MCPTool] = []
    /// The shared knowledge pool (notes and reads across projects); nil until the first load, and for good when it
    /// could not open (knowledge then stays in memory for the run).
    @ObservationIgnored var pool: KnowledgePool?
    /// The projects whose files this workspace's notes tools may name, refreshed with the view.
    @ObservationIgnored var knowledgeScope: KnowledgeScope
    /// The pool's `data_version` at the last load, and what the pool held for the rows in view (the diff baselines).
    @ObservationIgnored var poolVersion: Int64 = 0
    @ObservationIgnored var syncedNotes: [UUID: Note] = [:]
    @ObservationIgnored var syncedReads: [ReadGroup: [ReadEntry]] = [:]
    @ObservationIgnored var generationsSnapshot: [String: Int] = [:]
    /// Read groups changed since the last sync (the only ones `persistReads` looks at), and whether a pool failure was reported.
    @ObservationIgnored var dirtyReads: Set<ReadGroup> = []
    @ObservationIgnored var poolErrorReported = false
    /// The loopback MCP server; nil until the workspace has loaded, or when it could not start.
    @ObservationIgnored var localServer: LocalServer?
    @ObservationIgnored private var serverStart: Task<Void, Never>?
    /// Where sessions reach the local server, once it runs. Task 5 builds `--mcp-config` from this and `mcpToken(for:)`.
    public internal(set) var serverURL: URL?
    /// Tokens minted at launch, by session; revoked when the session stops or exits.
    @ObservationIgnored var mcpTokens: [UUID: String] = [:]
    /// Every file a session read, with the file's stamp at that moment (Plan 5a).
    public internal(set) var readIndex = ReadIndex()
    /// What each session was last told about each file (`told.json`), so a file is noted to a session once.
    public internal(set) var told: [UUID: [String: ToldEntry]] = [:]
    /// The files each user bubble's "shared" chip lists, by block id. A side table, so `ChatBlock.user` is unchanged.
    public internal(set) var sharedFiles: [UUID: [SharedFile]] = [:]
    /// Told.json writes: the newest unwritten snapshot, and whether a write task that will take it is queued.
    @ObservationIgnored var toldSnapshot: [String: [String: ToldEntry]]?
    @ObservationIgnored var toldWriteQueued = false
    /// Changed paths awaiting one batched note check (see `noteFileChanged`), and whether that check is scheduled.
    @ObservationIgnored var pendingNoteChecks: Set<String> = []
    @ObservationIgnored var noteCheckQueued = false
    /// How many batched note checks have run; tests watch it.
    @ObservationIgnored var noteCheckRuns = 0
    /// Sessions whose outgoing message is having its shared context computed; later sends wait their turn, so
    /// messages keep their order.
    /// Told-updates of messages built but not yet delivered. They count as told for the next message of the session
    /// (so two quick sends don't repeat a file), and become `told` only when their message is delivered.
    @ObservationIgnored var inflightTold: [PendingTold] = []
    /// Delivered messages (by their uuid) whose told-updates wait for the CLI's echo.
    @ObservationIgnored var awaitingEcho: [UUID: PendingTold] = [:]
    @ObservationIgnored var contextBusy: Set<UUID> = []
    @ObservationIgnored var contextWaiters: [UUID: [CheckedContinuation<Void, Never>]] = [:]
    /// Reads that were redundant when issued, across all sessions.
    public internal(set) var redundantReads = 0
    /// Bumped on each compaction and `/clear`; a read before the bump no longer counts as in the session's context.
    @ObservationIgnored var compactionGeneration: [UUID: Int] = [:]
    /// Task 4 fills this with "does the notes store hold a current note for this path and stamp".
    @ObservationIgnored var hasCurrentNote: @MainActor (String, FileStamp) -> Bool = { _, _ in false }
    /// Who has pending and applied changes where (Plan 5b); the hook handler asks it.
    @ObservationIgnored lazy var overlapIndex = OverlapIndex(
        ledger: { [weak self] in self?.ledger.files[$0] }, document: { [weak self] in self?.documents[$0] },
        now: { [weak self] in self?.now() ?? Date() })
    /// What each session was told about overlaps (`overlapTold.json`): key -> the compaction generation it was told at.
    @ObservationIgnored var overlapTold: [UUID: [String: Int]] = [:]
    @ObservationIgnored var overlapToldSnapshot: [String: [String: Int]]?
    @ObservationIgnored var overlapToldWriteQueued = false
    @ObservationIgnored var overlapToldWrite: Task<Void, Never>?
    /// Tug-of-war alerts for Task 7's UI. Live-only by design: they are never written to disk, so a restart
    /// starts with none (an alert is about the last ten minutes of edits, which a restart makes stale).
    public internal(set) var tugAlerts: [TugAlert] = []
    @ObservationIgnored var tug = TugState()
    /// Overlap warnings the sessions were told about, for the markers and the notice (see `coordinationWarnings`).
    /// Live-only, like the tug alerts.
    var overlapWarnings: [OverlapWarningRecord] = []
    /// When each overlap chat notice was last shown, by receiving session and text (see `overlapNoticeWindow`).
    @ObservationIgnored var overlapNoticeShown: [OverlapNoticeKey: Date] = [:]
    /// The tools each live session was launched with in `--allowedTools`; a permission request for one is answered allow.
    @ObservationIgnored var launchAllowedTools: [Session.ID: Set<String>] = [:]
    /// Warnings whose notice strip the user dismissed or followed.
    public internal(set) var dismissedWarnings: Set<DismissedWarning> = []
    /// Wakes when the earliest warning expires, so the screen drops it without a per-frame timer. Not tracked, so
    /// `settle()` never waits for it; `stopAll()` cancels it.
    @ObservationIgnored var warningSleeper: Task<Void, Never>?
    @ObservationIgnored var warningSleeperExpiry: Date?
    /// Advisory claims on regions of files (`claims.json`).
    @ObservationIgnored public internal(set) var claims: [Claim] = []
    @ObservationIgnored var claimsSnapshot: [Claim]?
    @ObservationIgnored var claimsWriteQueued = false
    @ObservationIgnored var claimsWrite: Task<Void, Never>?
    /// The four coordination tools the local server offers next to the notes tools.
    @ObservationIgnored public private(set) var coordinationTools: [MCPTool] = []
    /// The UI the theme tools reach (Plan 7b); set by the app's theme controller.
    @ObservationIgnored public weak var themeWorkshop: ThemeWorkshop?
    /// The five theme tools, offered only to theme sessions.
    @ObservationIgnored public private(set) var themeTools: [MCPTool] = []
    /// Session messages delivered within the last minute, for the rate limits.
    @ObservationIgnored var messageLog: [(from: UUID, to: UUID, at: Date)] = []
    /// The project root as hook paths may spell it: standardised and symlink-resolved (computed once, in `init`).
    @ObservationIgnored var hookRootForms: [String] = []
    /// Hook `file_path` -> project-relative path, so a repeated path costs a lookup.
    @ObservationIgnored var hookPathCache: [String: String] = [:]
    /// Read tool_use ids already judged, so a repeated delivery of a block is not counted twice.
    @ObservationIgnored var judgedReads: Set<String> = []
    /// Read tool_use id -> file_path, until the result arrives (a subagent's result has no structured file info).
    @ObservationIgnored var warnedReadFormat = false
    @ObservationIgnored var pendingReadPaths: [String: String] = [:]
    @ObservationIgnored var decorationBuildCount = 0
    @ObservationIgnored var sideBySideBuildCount = 0
    @ObservationIgnored private var mergeBusy: Set<String> = []
    @ObservationIgnored private var mergeQueue: [String: [CheckedContinuation<Void, Never>]] = [:]
    @ObservationIgnored let autosaveClock: any AutosaveClock
    @ObservationIgnored private var autosaveStore: Autosave?
    private var autosave: Autosave {
        if let a = autosaveStore { return a }
        let a = Autosave(clock: autosaveClock) { [weak self] path in try? await self?.save(path) }
        autosaveStore = a
        return a
    }
    /// Messages about the user's work for the UI to show (for example a session edit that overlapped unsaved typing).
    public internal(set) var notices: [Notice] = []
    @ObservationIgnored private var opening: Set<String> = []
    /// Callers of `open` that arrived while the same path was being read; resumed when that read finished.
    @ObservationIgnored private var openWaiters: [String: [CheckedContinuation<Void, Never>]] = [:]
    @ObservationIgnored private var closing: Set<String> = []
    /// Paths opened again while their close was writing; that close then aborts.
    @ObservationIgnored private var reopened: Set<String> = []
    @ObservationIgnored var syncGeneration: [String: Int] = [:]
    /// Workspace-wide, so a reopened file never reuses a generation an earlier refresh still holds.
    @ObservationIgnored private var syncCounter = 0
    /// Fire-and-forget work (alias opens, session-edit syncs) that `settle()` awaits.
    @ObservationIgnored private var background: [Int: Task<Void, Never>] = [:]
    @ObservationIgnored private var backgroundCounter = 0
    /// When the watcher last delivered an event for a project-relative path, on the injected clock.
    @ObservationIgnored var recentArrival: [String: Double] = [:]
    /// `lastSessionEditor` answers by path, valid for the ledger version they were scanned at (see PanelActions.swift).
    @ObservationIgnored var editorCache: [String: (version: Int, author: Author?)] = [:]
    /// How many times a ledger was actually scanned for its last session editor (tests read it).
    @ObservationIgnored package var editorScans = 0
    /// Called with the changed paths under `.git/` (absolute), coalesced like other outside changes. Task 5 sets it.
    @ObservationIgnored public var gitChanged: (([String]) -> Void)?
    // Outside-edit watcher state (see OutsideEdits.swift).
    @ObservationIgnored let changeFactory: (URL) -> any FileChangeSource
    @ObservationIgnored var watchTask: Task<Void, Never>?
    /// Changed paths waiting for the coalescing window, with the clock time each first arrived.
    @ObservationIgnored var pendingOutside: [String: Double] = [:]
    @ObservationIgnored var eventRoots: [String] = []
    /// Paths whose deletion (with unsaved typing) the user has been told about, until the file is seen again.
    @ObservationIgnored var deletedNotified: Set<String> = []
    /// Per session, when its shell tool calls ran (see `diskChangeAuthor(at:)`).
    @ObservationIgnored var shellWindows: [Session.ID: [ShellWindow]] = [:]
    /// The bytes a refresh in flight is bringing into the buffer, by path.
    @ObservationIgnored var syncTarget: [String: (generation: Int, bytes: [UInt8])] = [:]
    @ObservationIgnored var outsideDebounce: Task<Void, Never>?
    /// The 500 ms window after a HEAD, branch or index change before ledger files are compared with HEAD.
    @ObservationIgnored var gitDebounce: Task<Void, Never>?
    @ObservationIgnored var lastBaselineEvent: Double?
    /// The git directory when it lies outside the project root (a worktree's, or a repository above the root), and
    /// the second watcher on it.
    @ObservationIgnored var externalGitDir: String?
    @ObservationIgnored var gitWatchTask: Task<Void, Never>?
    @ObservationIgnored var abandonedWaiters: Set<UUID> = []
    @ObservationIgnored var toolResultWaiters: [UUID: CheckedContinuation<Void, Never>] = [:]

    /// Runs `body` in the background; `settle()` waits for it, and the entry is dropped when it finishes.
    @discardableResult
    func track(_ body: @escaping @MainActor () async -> Void) -> Task<Void, Never> {
        backgroundCounter += 1
        let id = backgroundCounter
        let task = Task { @MainActor [weak self] in
            await body()
            self?.background.removeValue(forKey: id)
        }
        background[id] = task
        return task
    }
    /// Test counters: files the watcher read, git processes it started, shell activity windows held.
    @ObservationIgnored var outsideReadCount = 0
    @ObservationIgnored var gitSpawnCount = 0
    /// How many tracked background tasks are still registered (for tests).
    var backgroundCount: Int { background.count }

    /// Test-only gates (nil in production): `refreshGate` runs before a refresh computes its diff, with the path
    /// and the new bytes; `closeGate` runs in `close` after the snapshot is taken and before the write.
    @ObservationIgnored var refreshGate: (@Sendable (String, [UInt8]) async -> Void)?
    @ObservationIgnored var closeGate: (@Sendable (String) async -> Void)?
    /// Test-only: runs in a revert's off-main work after it read the disk and before it computes the revert.
    @ObservationIgnored var revertGate: (@Sendable (String) async -> Void)?
    /// Test-only: runs in a revert's off-main write, after the ledger check and before the file is written.
    @ObservationIgnored var revertWriteGate: (@Sendable (String) async -> Void)?
    /// Test-only gate: `requestOpen` runs it after it is asked to open, before it looks up the edit's line.
    @ObservationIgnored var firstLineGate: (@Sendable (UUID) async -> Void)?
    /// Counts `requestOpen` calls; only the newest one opens (an older one still looking up its line is dropped).
    @ObservationIgnored var openRequestTicket = 0

    /// Waits for the alias opens and session-edit syncs started so far (for tests and orderly shutdown).
    public func settle() async {
        while !background.isEmpty {
            for t in Array(background.values) { await t.value }
        }
        await ledgerWrite?.value
        await generationsWrite?.value
        pool?.flush()
        await toldWrite?.value
        await overlapToldWrite?.value
        await claimsWrite?.value
        await serverStart?.value
    }
    public var changedFiles: [ChangedFile] { ledger.changedFiles() }
    /// Persistence problems for the UI to show (corrupt files moved aside, failed saves).
    public private(set) var errors: [String] = []

    /// Per edit, the diff lines its chat block shows (the edit's runs plus two lines of context). Computed
    /// when the edit is recorded; frozen across keep and revert.
    public private(set) var editDiffs: [UUID: [DiffLine]] = [:]
    /// Why a revert was refused, until a later revert or keep of that edit succeeds.
    public internal(set) var revertConflicts: [UUID: String] = [:]
    /// How many full-file `diffLines()` computations have run (for tests).
    @ObservationIgnored public private(set) var diffComputations = 0
    @ObservationIgnored private var diffCache: [String: (version: Int, lines: [DiffLine])] = [:]
    @ObservationIgnored private var recordIndex: [UUID: EditRecord] = [:]

    @ObservationIgnored package let appSupport: URL
    public private(set) var settings: AlloySettings
    @ObservationIgnored package private(set) var settingsGeneration = 0
    /// The `claude` path auto-detection finds, once `detectClaude()` has run.
    public private(set) var detectedClaudePath: String?
    @ObservationIgnored private let locate: @Sendable (String?) throws -> URL
    @ObservationIgnored private let makeTransport: TransportFactory
    /// The login shell's PATH, merged into every child's environment (a GUI launch has a minimal PATH).
    @ObservationIgnored private let loginPATH: @Sendable () -> String?
    @ObservationIgnored private var cachedLoginPATH: String??
    @ObservationIgnored let now: () -> Date
    /// Writes the file; `abortIf` is asked right before the rename and a true answer leaves the file alone (the result is then true).
    @ObservationIgnored private let writeFile: @Sendable (Data, URL, () -> Bool) throws -> Bool
    @ObservationIgnored var live: [UUID: (transport: any SessionTransport, task: Task<Void, Never>)] = [:]
    /// Sessions whose `stop()` arrived while they were still launching.
    @ObservationIgnored private var stoppedDuringLaunch: Set<UUID> = []
    /// Messages sent before the transport was live, delivered (in order) once it is.
    @ObservationIgnored private var queued: [UUID: [(message: OutgoingMessage, uuid: UUID, context: String?, pending: PendingTold?)]] = [:]
    /// Sessions that must relaunch at their next idle point because a launch setting changed.
    @ObservationIgnored private var pendingRelaunch: Set<UUID> = []
    /// Whether any session is waiting to be relaunched at its next idle point.
    package var hasPendingRelaunch: Bool { !pendingRelaunch.isEmpty }
    /// Sessions whose process is being replaced; sends meanwhile join the queue.
    @ObservationIgnored private var relaunching: Set<UUID> = []
    /// Sessions that were handed a user message whose turn has not begun or ended: the session still reads idle
    /// until the CLI's init arrives, but a relaunch now would cut the turn off.
    /// The conversation a fork made in this run shows as its earlier history.
    @ObservationIgnored private var forkHistorySource: [UUID: String] = [:]
    @ObservationIgnored private var forkHistoryPoint: [UUID: String] = [:]
    @ObservationIgnored private var turnPending: Set<UUID> = []
    /// Forks waiting for their source's next idle point. The flag tells whether the source reached idle (true) or
    /// ended some other way (false: stopped, exited or the app is quitting).
    @ObservationIgnored private var idleWaiters: [UUID: [CheckedContinuation<Bool, Never>]] = [:]
    /// Control requests Alloy issued and has not seen answered, by `request_id`.
    @ObservationIgnored private var pendingControls: [String: (session: UUID, kind: PendingControlKind)] = [:]
    /// The original input of each open question or plan prompt, which the answer must echo back.
    @ObservationIgnored private var promptInputs: [String: (session: UUID, input: JSONValue)] = [:]
    /// Sessions whose queued messages are being delivered; new sends join the queue to keep order.
    @ObservationIgnored private var draining: Set<UUID> = []
    /// Sessions whose process exited while their queued messages were still being delivered.
    @ObservationIgnored private var exitedWhileDraining: Set<UUID> = []
    /// Called after a save wrote a document to disk and marked it saved, with the project-relative path.
    @ObservationIgnored public var onSaved: (@MainActor (String) -> Void)?
    /// Called when a settings update changed the language-server overrides.
    @ObservationIgnored public var onLanguageServersChanged: (@MainActor ([String: ServerConfigOverride]) -> Void)?
    /// Awaited at the end of `stopAll()`: whatever else must stop before the app quits (the language servers).
    @ObservationIgnored public var onStop: (@MainActor () async -> Void)?
    /// Go to Definition for the active tab's caret (set by the code panel; the menu and F12 call it).
    @ObservationIgnored public var goToDefinition: (@MainActor () -> Void)?
    /// Opens the Settings view over the chat column (set by the root view; the app menu's "Settings…" calls it).
    /// Settings already open stays open.
    @ObservationIgnored public var openSettings: (@MainActor () -> Void)?
    /// An opaque slot for the UI layer's language-server coordinator (AlloyCore cannot name that type).
    @ObservationIgnored public var languageServices: AnyObject?
    /// Set by `stopAll()` and never cleared: from then on nothing launches a process.
    public private(set) var isShuttingDown = false
    /// Launches between their start and end; `stopAll()` waits for them to drain.
    @ObservationIgnored private var launchesInFlight = 0
    @ObservationIgnored private var launchWaiters: [CheckedContinuation<Void, Never>] = []
    @ObservationIgnored private var restored = false
    @ObservationIgnored private let home: URL
    /// Restored sessions with a conversation whose earlier history has not been read yet.
    @ObservationIgnored private var historyPending: Set<UUID> = []
    /// Whether the session's earlier conversation is still to be loaded into its transcript.
    public func isHistoryPending(_ id: Session.ID) -> Bool { historyPending.contains(id) }
    @ObservationIgnored private var historyLoads: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored var loaded = false
    @ObservationIgnored var records: [SessionRecord] = []
    @ObservationIgnored private var cachedExecutable: URL?

    public init(projectRoot: URL, appSupport: URL, settings: AlloySettings,
                locate: @escaping @Sendable (String?) throws -> URL = {
                    try ClaudeLocator.locate(override: $0, loginShellLookup: ClaudeLocator.loginShellLookup,
                                             isExecutable: { FileManager.default.isExecutableFile(atPath: $0) },
                                             home: NSHomeDirectory())
                },
                makeTransport: @escaping TransportFactory = { ClaudeProcess(configuration: $0) },
                loginPATH: @escaping @Sendable () -> String? = { nil },
                now: @escaping () -> Date = Date.init,
                writeFile: @escaping @Sendable (Data, URL, () -> Bool) throws -> Bool = { try Workspace.writeKeepingMode($0, to: $1, abortIf: $2) },
                home: URL = FileManager.default.homeDirectoryForCurrentUser,
                autosaveClock: any AutosaveClock = SystemAutosaveClock(),
                changes: @escaping (URL) -> any FileChangeSource = { FSEventsSource(root: $0) },
                poolBusyTimeoutMS: Int = 1000) {
        self.poolBusyTimeoutMS = poolBusyTimeoutMS
        self.autosaveClock = autosaveClock
        self.changeFactory = changes
        self.home = home
        self.fileIndex = FileIndex(root: projectRoot)
        self.projectRoot = projectRoot; self.appSupport = appSupport; self.settings = settings
        self.locate = locate; self.loginPATH = loginPATH; self.makeTransport = makeTransport; self.now = now; self.writeFile = writeFile
        self.ledger = ProjectLedger(projectRoot: projectRoot)
        self.knowledgeScope = KnowledgeScope(ownRoot: projectRoot.path)
        self.hasCurrentNote = { [weak self] path, stamp in
            self?.notes.notes(for: .file(path)).contains { $0.stamp == stamp } ?? false
        }
        self.notesTools = NotesTools.make(workspace: self)
        self.coordinationTools = CoordinationTools.make(workspace: self)
        self.themeTools = ThemeTools.make(workspace: self)
        self.hookRootForms = Self.hookRootForms(of: projectRoot)
    }

    // MARK: Local server

    /// Test seam: makes the next server start fail, as a busy or denied listener would.
    @ObservationIgnored package var failServerStartForTesting = false

    /// Starts the loopback MCP server once. A failure is reported and the editor carries on without notes.
    func startServer() async {
        if let serverStart { await serverStart.value; return }
        guard !isShuttingDown else { return }
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            let server = LocalServer(tools: notesTools + coordinationTools + themeTools, onListenerFailure: { [weak self] error in
                Task { @MainActor in await self?.listenerFailed(error) }
            }, report: { [weak self] message in
                Task { @MainActor in self?.report(message) }
            })
            await server.setHookHandler { [weak self] request, caller in
                await self?.answerHook(request, caller) ?? HookReply()
            }
            do {
                if failServerStartForTesting { throw CocoaError(.fileWriteUnknown) }
                let url = try await server.start()
                if isShuttingDown { await server.stop(); return }
                localServer = server
                serverURL = url
            } catch {
                report("Shared notes are unavailable: \(error.localizedDescription)")
            }
        }
        serverStart = task
        await task.value
    }

    /// The listener died after it was ready. Its port is free again, so nothing may keep pointing sessions at it: a
    /// process that took the port would be handed each new session's bearer token and could answer pre-approved tool
    /// calls. New launches go without sharing; sessions already running keep a dead URL until their next relaunch.
    package func listenerFailed(_ error: Error) async {
        report("Shared notes stopped working: \(error.localizedDescription)")
        let server = localServer
        localServer = nil
        serverURL = nil
        mcpTokens.removeAll()
        await server?.stop()
    }

    /// The bearer token for a session, minted on first use. Nil when the server is not running.
    func mcpToken(for id: UUID, scopes: Set<MCPToolScope>) async -> String? {
        await startServer()
        await revocations[id]?.value
        guard !isShuttingDown, let server = localServer else { return nil }
        let token = await server.token(for: id, scopes: scopes)
        mcpTokens[id] = token
        return token
    }

    /// Revocations in flight; a relaunch of the same session waits for its own, so a new token is never revoked.
    @ObservationIgnored private var revocations: [UUID: Task<Void, Never>] = [:]

    private func revokeToken(for id: UUID) {
        guard mcpTokens.removeValue(forKey: id) != nil, let server = localServer else { return }
        let previous = revocations[id]
        revocations[id] = track { [weak self] in
            await previous?.value
            await server.revoke(session: id)
            if self?.mcpTokens[id] == nil { self?.revocations.removeValue(forKey: id) }
        }
    }

    // MARK: Sessions

    @discardableResult
    public func newSession(name: String) async -> Session { await newSession(name: name, purpose: .coding) }

    /// `/theme [description]`: a new session that makes a theme with the user. Its first message is the description
    /// (or a stock opening line), because a stream-json session sits silent until it gets one.
    @discardableResult
    public func newThemeSession(description: String?) async -> Session {
        let trimmed = description?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let shown = trimmed.count > 40 ? String(trimmed.prefix(40)) + "\u{2026}" : trimmed
        let s = await newSession(name: trimmed.isEmpty ? "Theme: new" : "Theme: \(shown)", purpose: .theme)
        guard session(s.id) != nil else { return s }
        selectedSessionID = s.id
        let first = trimmed.isEmpty ? "Help me make an Alloy theme." : trimmed
        await send(OutgoingMessage(text: first, images: [], priority: nil), to: s.id, routeSlash: false)
        return s
    }

    /// The "+" button and ⌘N: creates a session and switches to it. `newSession` alone selects only when nothing is
    /// selected (restore and theme paths rely on that).
    @discardableResult
    public func newSessionFromUser(name: String) async -> Session {
        await newSession(name: name, purpose: .coding, select: true)
    }

    @discardableResult
    func newSession(name: String, purpose: SessionPurpose, select: Bool = false) async -> Session {
        ensureLoaded()
        let s = Session(id: UUID(), name: allowedName(name, for: nil), colorIndex: records.count % 12, projectRoot: projectRoot,
                        purpose: purpose)
        if Self.isReserved(name) { s.transcript.appendNotice(kind: .commandOutput, text: Self.reservedNotice(for: s.name)) }
        if isShuttingDown {
            // Not registered and never launched; the caller gets a stopped session.
            s.status = .exited(status: 0, message: "Stopped")
            return s
        }
        sessions.append(s)
        if select || selectedSessionID == nil { selectedSessionID = s.id }
        persistSessions()
        await launch(s, resume: false)
        return s
    }

    /// Resolved once, off the main actor (the login-shell lookup can take seconds), then cached.
    private func resolveExecutable() async throws -> URL {
        if let cachedExecutable { return cachedExecutable }
        let locate = self.locate
        let path = settings.effectiveClaudePath()
        let loginPATH = self.loginPATH
        let generation = settingsGeneration
        let (url, login) = try await Task.detached { (try locate(path), loginPATH()) }.value
        // Settings changed while locating: this result is for the old path, so use it once but do not cache it.
        if generation == settingsGeneration {
            cachedExecutable = url
            cachedLoginPATH = .some(login)
        }
        return url
    }

    /// Saves to Alloy's own settings file and applies to launches from now on. Running sessions are untouched.
    public func updateSettings(_ s: AlloySettings) throws {
        try s.save(appSupport: appSupport)
        let launchOptionsChanged = s.shareKnowledge != settings.shareKnowledge
            || s.askBeforeSharedNotes != settings.askBeforeSharedNotes
            || s.shareAcrossProjects != settings.shareAcrossProjects
        let visibilityChanged = s.shareKnowledge != settings.shareKnowledge || s.shareAcrossProjects != settings.shareAcrossProjects
        let serversChanged = s.languageServers != settings.languageServers
        settings = s
        if serversChanged { onLanguageServersChanged?(s.languageServers) }
        if visibilityChanged { reloadKnowledgeAfterSettingsChange() }
        settingsGeneration += 1
        cachedExecutable = nil
        // Live sessions pick up the new launch options at their next idle point; dormant ones at their next wake.
        if launchOptionsChanged {
            for session in sessions where live[session.id] != nil || session.status == .starting { relaunchWhenIdle(session.id) }
        }
    }

    /// Replaces the session's process with a fresh `--resume` one carrying the current settings, once the session
    /// is idle. A running turn is never cut off. A dormant session needs nothing: its next wake uses the settings.
    public func relaunchWhenIdle(_ id: Session.ID) {
        guard let s = session(id), live[id] != nil || s.status == .starting else { return }
        pendingRelaunch.insert(id)
        if s.status == .idle { track { [weak self] in await self?.applyPendingRelaunch(id) } }
    }

    private func isAtRest(_ s: Session) -> Bool { s.status == .idle && s.queued.isEmpty && !turnPending.contains(s.id) }

    private func applyPendingRelaunch(_ id: Session.ID) async {
        guard pendingRelaunch.contains(id), let s = session(id), !isShuttingDown, isAtRest(s), live[id] != nil,
              !draining.contains(id), !relaunching.contains(id), queued[id]?.isEmpty ?? true else { return }
        pendingRelaunch.remove(id)
        relaunching.insert(id)
        defer { relaunching.remove(id) }
        // From here sends join the queue (a starting session's way), and the queue survives the swap.
        s.status = .starting
        exitedWhileDraining.remove(id)
        forgetPending(for: id)
        releaseAwaitingEcho(for: id)
        revokeToken(for: id)
        if let entry = live.removeValue(forKey: id) {
            entry.task.cancel()
            shellWindows.removeValue(forKey: id)
            // Waited for, so two processes never resume one conversation at once. The CLI restores the model and
            // the permission mode on `--resume` (probed), so nothing is re-sent.
            await entry.transport.stopAndWait(timeout: .seconds(3))
        }
        turnPending.remove(id)
        s.transcript.finalizeStreaming()
        s.transcript.interruptRunningTools()
        await checkForkPoint(s)
        await launch(s, resume: s.hasConversation || s.forkSource != nil, forkFrom: s.forkSource, forkAt: s.forkPoint)
        if live[id] != nil { s.transcript.appendNotice(kind: .commandOutput, text: "Settings applied") }
    }

    /// Called as events arrive: lets work that waited for the session's idle point go.
    private func sessionMayBeIdle(_ s: Session) {
        guard isAtRest(s) else { return }
        if let waiters = idleWaiters.removeValue(forKey: s.id) { for w in waiters { w.resume(returning: true) } }
        if pendingRelaunch.contains(s.id) { track { [weak self] in await self?.applyPendingRelaunch(s.id) } }
    }

    private func releaseIdleWaiters(_ id: UUID, reachedIdle: Bool) {
        if let waiters = idleWaiters.removeValue(forKey: id) { for w in waiters { w.resume(returning: reachedIdle) } }
    }

    // MARK: Fork

    /// Starts a new session from a copy of the session's conversation (`--resume <id> --fork-session`). The source
    /// keeps going on its own. Returns nil, with a notice in the source's chat, when there is nothing to fork.
    /// A running source is forked at its next idle point.
    @discardableResult
    public func fork(_ id: Session.ID, name: String?) async -> Session? {
        await afterEarlierSends(id)
        guard let source = session(id), !isShuttingDown else { return nil }
        guard source.hasConversation else {
            source.transcript.appendNotice(kind: .error, text: "Nothing to fork yet")
            return nil
        }
        if source.status == .working || source.status == .awaitingPermission || !source.queued.isEmpty {
            source.transcript.appendNotice(kind: .commandOutput, text: "Forking when idle\u{2026}")
            let go = await withCheckedContinuation { (c: CheckedContinuation<Bool, Never>) in
                idleWaiters[id, default: []].append(c)
            }
            guard go, !isShuttingDown, session(id) != nil else {
                if !isShuttingDown { source.transcript.appendNotice(kind: .error, text: "Fork cancelled") }
                return nil
            }
        }
        ensureLoaded()
        // The point the fork starts from. An unsent fork being forked again keeps its own point (it has no file yet).
        let point: String?
        if source.forkSource != nil { point = source.forkPoint } else {
            let url = TranscriptFile.url(cliSessionID: source.cliSessionID, projectRoot: projectRoot, home: home)
            point = await Task.detached { () -> String? in
                guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return nil }
                return TranscriptFile.lastMessageUUID(in: data)
            }.value
            if isShuttingDown || session(id) == nil { return nil }
        }
        let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let fork = Session(id: UUID(), name: trimmed.isEmpty ? "\(source.name) (fork)" : allowedName(trimmed, for: nil),
                           colorIndex: records.count % 12, projectRoot: projectRoot,
                           hasConversation: true, model: source.model, permissionMode: source.permissionMode,
                           forkSource: source.forkSource ?? source.cliSessionID, forkPoint: point, purpose: source.purpose)
        if Self.isReserved(trimmed) { fork.transcript.appendNotice(kind: .commandOutput, text: Self.reservedNotice(for: fork.name)) }
        sessions.append(fork)
        // Before the selection: selecting a session with pending history is what loads it, at the fork point.
        historyPending.insert(fork.id)
        forkHistorySource[fork.id] = fork.forkSource
        forkHistoryPoint[fork.id] = fork.forkPoint
        selectedSessionID = fork.id
        readIndex.copy(from: source.id, to: fork.id, generation: compactionGeneration[fork.id, default: 0],
                       fromGeneration: compactionGeneration[source.id, default: 0])
        for e in readIndex.entries(of: fork.id) { markReadDirty(session: fork.id, key: e.path) }
        persistReads()
        copyTold(from: source.id, to: fork.id)
        copyOverlapTold(from: source.id, to: fork.id)
        persistSessions()
        await launch(fork, resume: true, forkFrom: fork.forkSource, forkAt: fork.forkPoint)
        return fork
    }

    /// Fork launches that passed `--resume-session-at` and have not shown their init yet.
    @ObservationIgnored private var launchedAtForkPoint: Set<UUID> = []

    /// Whether a CLI's exit text says it refused the fork point (the flag itself, or a uuid it does not know:
    /// "No message found with message.uuid of: ...").
    private static func rejectsForkPoint(_ stderr: String) -> Bool {
        let t = stderr.lowercased()
        return t.contains("resume-session-at") || t.contains("unknown option") || t.contains("no message found")
    }

    /// The CLI refused the fork point before the fork's first init: drop it and launch once more from the source's
    /// latest point. The retry carries no point, so it cannot loop.
    private func retryWithoutForkPoint(_ s: Session) async {
        guard !isShuttingDown, session(s.id) != nil, s.forkPoint != nil, s.forkSource != nil, case .exited = s.status else { return }
        s.forkPoint = nil
        persistSessions()
        s.transcript.appendNotice(kind: .commandOutput,
                                  text: "Couldn't fork at the exact point; the fork starts from the source's latest point.")
        s.status = .starting
        await launch(s, resume: true, forkFrom: s.forkSource, forkAt: nil)
    }

    /// Before an unsent fork launches: the CLI refuses a `--resume-session-at` uuid its source file does not hold, so a
    /// point that is gone is dropped (the fork then starts from the source's latest point) and the user is told.
    private func checkForkPoint(_ s: Session) async {
        guard let source = s.forkSource, let point = s.forkPoint else { return }
        let url = TranscriptFile.url(cliSessionID: source, projectRoot: projectRoot, home: home)
        let there = await Task.detached { () -> Bool in
            guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return true }   // a missing file is wake's concern
            return TranscriptFile.contains(data, uuid: point)
        }.value
        guard !there, s.forkPoint == point else { return }
        s.forkPoint = nil
        s.transcript.appendNotice(kind: .commandOutput, text: "This fork's source has moved on; the fork now starts from its latest point.")
        persistSessions()
    }

    /// Fills `detectedClaudePath` with what auto-detection finds (no override), for the settings placeholder.
    /// Runs the lookup once; later calls keep the first answer.
    public func detectClaude() async {
        if detectedClaudePath != nil { return }
        let locate = self.locate
        detectedClaudePath = await Task.detached { (try? locate(nil))?.path }.value
    }

    private func launch(_ s: Session, resume: Bool, forkFrom: String? = nil, forkAt: String? = nil) async {
        if isShuttingDown { markStopped(s); return }
        launchesInFlight += 1
        exitedWhileDraining.remove(s.id)
        defer {
            stoppedDuringLaunch.remove(s.id)
            exitedWhileDraining.remove(s.id)
            launchesInFlight -= 1
            if launchesInFlight == 0 {
                let waiters = launchWaiters
                launchWaiters.removeAll()
                for w in waiters { w.resume() }
            }
        }
        let exe: URL
        do { exe = try await resolveExecutable() } catch let e as ClaudeNotFound {
            failLaunch(s, "claude not found. Tried: \(e.tried.joined(separator: ", ")). Set a path in Alloy settings or ALLOY_CLAUDE_PATH.")
            return
        } catch {
            failLaunch(s, "Could not locate claude: \(error.localizedDescription)")
            return
        }
        // Sharing needs the server and this session's token; without either the session launches as if sharing were off.
        var scopes: Set<MCPToolScope> = settings.shareKnowledge ? [.shared] : []
        if s.purpose == .theme { scopes.insert(.theme) }
        let shared = scopes.contains(.shared), theme = scopes.contains(.theme)
        let token = scopes.isEmpty ? nil : await mcpToken(for: s.id, scopes: scopes)
        if stoppedDuringLaunch.contains(s.id) || isShuttingDown { markStopped(s); return }
        s.beginProcess()
        // The CLI keeps the model on a fork but starts it in the default permission mode (probed): a fork's
        // process gets the mode the fork inherited, whether it is new, woken or relaunched before its first turn.
        if forkFrom != nil, let mode = s.permissionMode.flatMap(PermissionMode.init(rawValue:)),
           !(deferredControls[s.id] ?? []).contains(where: { if case .mode = $0 { true } else { false } }) {
            deferredControls[s.id, default: []].insert(.mode(mode), at: 0)
        }
        var configuration = LaunchConfiguration(executable: exe, projectDirectory: projectRoot,
                                                sessionID: s.id, resume: resume,
                                                resumeID: resume ? (forkFrom ?? s.cliSessionID) : nil,
                                                loginPATH: cachedLoginPATH ?? nil)
        configuration.forkSession = forkFrom != nil
        configuration.resumeSessionAt = forkFrom != nil ? forkAt : nil
        if configuration.resumeSessionAt != nil { launchedAtForkPoint.insert(s.id) } else { launchedAtForkPoint.remove(s.id) }
        if let token, let url = serverURL {
            configuration.mcpConfigJSON = MCPServer.config(url: url, token: token)
            if shared { configuration.extraSettingsJSON = Hooks.settingsJSON(url: url, token: token) }
            var prompts: [String] = []
            if shared { prompts.append(Guidance.text(shareKnowledge: settings.shareKnowledge, shareAcrossProjects: settings.shareAcrossProjects)) }
            if theme { prompts.append(ThemeGuidance.text) }
            configuration.appendSystemPrompt = prompts.joined(separator: "\n\n")
            configuration.allowedTools = settings.askBeforeSharedNotes ? []
                : (shared ? Guidance.alloyToolNames : []) + (theme ? Guidance.themeToolNames : [])
        } else if theme {
            s.transcript.appendNotice(kind: .error, text: "Theme tools are unavailable: Alloy's local server is not running.")
        }
        launchAllowedTools[s.id] = Set(configuration.allowedTools)
        let transport = makeTransport(configuration)
        let stream: AsyncStream<ProcessEvent>
        do { stream = try await transport.start() } catch {
            failLaunch(s, "Could not start claude: \(error.localizedDescription)")
            return
        }
        if stoppedDuringLaunch.contains(s.id) || isShuttingDown {
            await transport.stopAndWait(timeout: .seconds(3))
            markStopped(s)
            return
        }
        // stream-json emits init only after the first message, so a started session is idle.
        s.status = .idle
        let task = Task { @MainActor [weak self] in
            for await event in stream {
                guard let self else { return }
                self.handle(event, session: s)
            }
        }
        live[s.id] = (transport, task)
        draining.insert(s.id)
        defer { draining.remove(s.id) }
        // First on the wire, so the command list arrives before the user types a slash.
        await sendControl(.initialize, kind: .initialize, via: transport, to: s)
        // Model or mode changes asked for before the process was up go out before any queued message, so
        // "/plan" then "do X" on a dormant session runs "do X" in plan mode.
        while let c = deferredControls[s.id]?.first, live[s.id] != nil {
            deferredControls[s.id]?.removeFirst()
            switch c {
            case .model(let m): await sendControl(.setModel(m), kind: .setModel(m), via: transport, to: s)
            case .mode(let m): await sendControl(.setPermissionMode(m.rawValue), kind: .setMode(m.rawValue), via: transport, to: s)
            }
        }
        deferredControls.removeValue(forKey: s.id)
        // The last await before `draining` is released: a send that lands while a message is delivered joins
        // this loop, and nothing can land in the queue after it ends.
        while let m = queued[s.id]?.first {
            queued[s.id]?.removeFirst()
            // Stopped while delivering: drop the rest silently. Exited: say so once.
            guard live[s.id] != nil else {
                settleTold(m.pending, sent: false)
                discardQueue(for: s.id)
                if exitedWhileDraining.remove(s.id) != nil {
                    s.transcript.appendNotice(kind: .error, text: "Message not sent: session ended")
                }
                break
            }
            await deliverUser(.user(content: Self.content(m.message, context: m.context), uuid: m.uuid, priority: nil),
                              uuid: m.uuid, pending: m.pending, via: transport, to: s)
        }
        discardQueue(for: s.id)
        // A setting that changed while this launch ran takes effect at the first idle point after it.
        if pendingRelaunch.contains(s.id) { track { [weak self] in await self?.applyPendingRelaunch(s.id) } }
    }

    private enum PendingControl { case model(String), mode(PermissionMode) }
    @ObservationIgnored private var deferredControls: [Session.ID: [PendingControl]] = [:]

    /// A control asked for while no process runs: wake a dormant session, and apply it once the process is up.
    private func deferControl(_ c: PendingControl, for s: Session) async {
        guard s.status == .dormant || s.status == .starting else {
            if live[s.id] == nil { noteSessionEnded(s) }
            return
        }
        deferredControls[s.id, default: []].append(c)
        if s.status == .dormant { await wake(s.id) }
    }

    /// The one "Session has ended" notice a message or control sent to a dead session leaves.
    private func noteSessionEnded(_ s: Session) {
        let ended = s.transcript.blocks.contains { if case .notice(_, .error, "Session has ended") = $0 { return true } else { return false } }
        if !ended { s.transcript.appendNotice(kind: .error, text: "Session has ended") }
    }

    private func failLaunch(_ s: Session, _ message: String) {
        revokeToken(for: s.id)
        if stoppedDuringLaunch.contains(s.id) { markStopped(s); return }
        noteThemeSessionEnded(s.id)
        s.status = .failedToLaunch(message)
        deferredControls.removeValue(forKey: s.id)
        if discardQueue(for: s.id) {
            s.transcript.appendNotice(kind: .error, text: "Message not sent: Claude could not start")
        }
    }

    /// Tells the theme workshop a theme session's process is gone, so it can drop that session's preview.
    private func noteThemeSessionEnded(_ id: UUID) {
        guard session(id)?.purpose == .theme else { return }
        themeWorkshop?.themeSessionEnded(id)
    }

    private func markStopped(_ s: Session) {
        noteThemeSessionEnded(s.id)
        pendingRelaunch.remove(s.id)
        turnPending.remove(s.id)
        revokeToken(for: s.id)
        forgetPending(for: s.id)
        dropClaims(session: s.id)
        releaseAwaitingEcho(for: s.id)
        discardQueue(for: s.id)
        deferredControls.removeValue(forKey: s.id)
        s.transcript.finalizeStreaming()
        s.transcript.interruptRunningTools()
        s.status = .exited(status: 0, message: "Stopped")
    }

    private func handle(_ event: ProcessEvent, session s: Session) {
        let persisted = persistedState(s)
        if case .message(.controlResponse(let rid, let result)) = event {
            // Only answers to requests Alloy issued; anything else is not ours.
            if let pending = pendingControls[rid], pending.session == s.id {
                pendingControls.removeValue(forKey: rid)
                route(result, to: pending.kind, session: s)
            }
            return
        }
        // Plan mode asks about tools that were launched pre-approved; Alloy's own tools are answered here, with no card.
        if case .message(.controlRequest(let req)) = event, case .canUseTool(let name, let input, _, let tid, _) = req.kind,
           launchAllowedTools[s.id]?.contains(name) == true, let t = live[s.id]?.transport {
            Task { @MainActor [weak self] in await self?.deliver(.allow(requestID: req.requestID, updatedInput: input), via: t, to: s) }
            return
        }
        s.handle(event)
        switch event {
        case .message(.systemInit), .message(.result), .exited: turnPending.remove(s.id)
        default: break
        }
        sessionMayBeIdle(s)
        trackShellWindows(event, session: s)
        trackReads(event, session: s)
        if case .message(.userEcho(_, _, let uuid, _)) = event { noteEcho(uuid: uuid, session: s); noteTugEcho(uuid: uuid) }
        if case .message(.controlRequest(let req)) = event, case .canUseTool(let name, let input, _, _, _) = req.kind,
           name == "AskUserQuestion" || name == "ExitPlanMode" {
            promptInputs[req.requestID] = (s.id, input)
        }
        if case .message(.controlCancel(let rid)) = event { promptInputs.removeValue(forKey: rid) }
        if case .exited = event {
            pendingRelaunch.remove(s.id)
            noteThemeSessionEnded(s.id)
            releaseIdleWaiters(s.id, reachedIdle: false)
            revokeToken(for: s.id)
            forgetPending(for: s.id)
            dropClaims(session: s.id)
            releaseAwaitingEcho(for: s.id)
            if case .exited(_, let tail) = event, launchedAtForkPoint.remove(s.id) != nil, s.forkPoint != nil,
               Self.rejectsForkPoint(tail) {
                track { [weak self] in await self?.retryWithoutForkPoint(s) }
            }
            live.removeValue(forKey: s.id)
            if draining.contains(s.id) { exitedWhileDraining.insert(s.id) }
            resumeToolResultWaiters()
        }
        // Control requests Alloy does not handle get an error answer, so the CLI never waits for one.
        if case .message(.controlRequest(let req)) = event, case .other = req.kind, let t = live[s.id]?.transport {
            let reply = OutboundMessage.controlError(requestID: req.requestID, message: "Unsupported by Alloy")
            Task { @MainActor [weak self] in await self?.deliver(reply, via: t, to: s) }
        }
        if persistedState(s) != persisted { persistSessions() }
        if case .message(.toolResult(let r)) = event {
            // The tool finished (or failed): its proposal is over even if the PostToolUse hook never arrived.
            overlapIndex.resolve(toolUseID: r.toolUseID)
            if r.isError { dropWarnings(ofFailedTool: r.toolUseID) }
            let fileCount = ledger.files.count
            let recs = ledger.record(r.result, author: .session(s.id), toolUseID: r.toolUseID, date: now())
            if !recs.isEmpty {
                // Only this session's own edits belong to its tool block; an `.outside` record made by drift
                // detection (the user's own change) stays in the ledger but not in the chat.
                let mine = recs.filter { $0.author == .session(s.id) }
                let path = recs[0].path
                reindex(path)
                noteFileChanged(path)
                syncOpenBuffer(path, by: s)
                if let newest = mine.last { followEdit(newest, by: s) }
                if !mine.isEmpty {
                    s.transcript.attach(editIDs: mine.map(\.id), toToolUseID: r.toolUseID)
                    let lines = diffLines(path: path)
                    for rec in mine { editDiffs[rec.id] = DiffSlice.visible(lines, editIDs: [rec.id]) }
                }
            }
            if !recs.isEmpty || ledger.files.count != fileCount { persistLedger() }
            if !recs.isEmpty, !overlapTold.isEmpty { persistOverlapTold() }
            resumeToolResultWaiters()
        }
    }

    public func send(_ text: String, to id: Session.ID) async {
        await send(OutgoingMessage(text: text, images: [], priority: nil), to: id)
    }

    public func send(_ message: OutgoingMessage, to id: Session.ID) async {
        await send(message, to: id, routeSlash: true)
    }

    /// `routeSlash: false` sends the text verbatim, skipping slash-command routing (a theme's first message is the
    /// user's description, which may itself start with `/`).
    func send(_ message: OutgoingMessage, to id: Session.ID, routeSlash: Bool) async {
        guard let s = session(id) else { return }
        if isShuttingDown {
            s.transcript.appendNotice(kind: .error, text: "Message not sent: Alloy is quitting")
            return
        }
        switch routeSlash && message.images.isEmpty && message.origin == nil ? SlashCommands.route(message.text) : .passThrough {
        case .passThrough: break
        case .setModel(let name): await setModel(name, for: id); return
        case .setMode(let mode): await setPermissionMode(mode, for: id); return
        case .showModelPicker: s.requestModelPicker = true; return
        case .fork(let name): await fork(id, name: name); return
        case .theme(let description): await newThemeSession(description: description); return
        case .localHelp:
            s.transcript.appendNotice(kind: .commandOutput, text: SlashCommands.helpText(s.slashCommands))
            return
        }
        // A process that is gone (and not coming back) takes no message: say so without building anything.
        guard s.status == .dormant || s.status == .starting || live[id] != nil else {
            noteSessionEnded(s)
            return
        }
        // The bubble appears at once; building the shared context (an off-main hop over the candidate files) must
        // not delay the echo of what the user typed. A queue priority only means something while a turn runs.
        let uuid = message.uuid ?? UUID()
        let busy = s.status == .working || s.status == .awaitingPermission
        let priority = busy ? message.priority : nil
        let waitsForProcess = s.status == .dormant || s.status == .starting || draining.contains(id)
        if let origin = message.origin {
            s.transcript.appendSessionMessage(id: uuid, direction: origin.isSystem ? .system : .from, peer: AlreadyRead.oneLine(origin.senderName), peerID: origin.sender,
                                              text: origin.body, queued: waitsForProcess ? nil : priority, wire: message.text)
        } else {
            s.transcript.appendUser(text: message.text, imageCount: message.images.count, id: uuid, queued: waitsForProcess ? nil : priority)
        }
        // The shared-knowledge block is built once, here, so queued and live sends agree. The bubble keeps the typed
        // text; the block only joins the wire content. Sends of one session pass this point in order.
        await acquireContext(id)
        // A message from another session is not the user's: it names no files to share.
        let context = message.origin == nil ? await sharedContext(for: s, message: message.text) : nil
        releaseContext(id)
        if isShuttingDown {
            settleTold(context?.pending, sent: false)
            s.transcript.appendNotice(kind: .error, text: "Message not sent: Alloy is quitting")
            return
        }
        // Context is computed now, at send time, even for a queued or dormant session; a message that never goes
        // out leaves `told` alone, so the next send tells again.
        if let context { sharedFiles[uuid] = context.files }
        if s.status == .dormant {
            // First message to a restored session: queue it and start the process (resuming when it has a conversation).
            queued[id, default: []].append((message, uuid, context?.text, context?.pending))
            await wake(id)
            return
        }
        if draining.contains(id), live[id] != nil {
            queued[id, default: []].append((message, uuid, context?.text, context?.pending))
            return
        }
        guard let t = live[id]?.transport else {
            if s.status == .starting {
                queued[id, default: []].append((message, uuid, context?.text, context?.pending))
                return
            }
            // Exited while the context was built: the bubble is already shown, so say it did not go out.
            settleTold(context?.pending, sent: false)
            s.transcript.appendNotice(kind: .error, text: "Message not sent: session ended")
            noteSessionEnded(s)
            return
        }
        await deliverUser(.user(content: Self.content(message, context: context?.text), uuid: uuid, priority: priority),
                          uuid: uuid, pending: context?.pending, via: t, to: s)
    }

    /// Sends a user message. What it tells the session becomes `told` when the CLI echoes the message's uuid (it
    /// reports a message when it takes it up), not when the transport takes the bytes: the CLI can still drop a queued
    /// message or exit first. Until then the claim stays in `inflightTold`, so quick follow-ups don't repeat it.
    private func deliverUser(_ m: OutboundMessage, uuid: UUID, pending: PendingTold?, via t: any SessionTransport, to s: Session) async {
        // Registered before the send: the echo can arrive while the send is still being awaited.
        if let pending { awaitingEcho[uuid] = pending }
        if !(await deliver(m, via: t, to: s)) {
            awaitingEcho.removeValue(forKey: uuid)
            settleTold(pending, sent: false)
        }
    }

    /// The CLI took up a message: what it told is now in the session's context.
    private func noteEcho(uuid: String?, session s: Session) {
        guard let uuid, let u = UUID(uuidString: uuid), let pending = awaitingEcho[u], pending.session == s.id else { return }
        awaitingEcho.removeValue(forKey: u)
        settleTold(pending, sent: true)
    }

    /// Messages that reached the transport but were never echoed (the process ended or was replaced) told nothing.
    private func releaseAwaitingEcho(for id: UUID) {
        for (uuid, pending) in awaitingEcho where pending.session == id {
            awaitingEcho.removeValue(forKey: uuid)
            settleTold(pending, sent: false)
        }
    }

    /// The shared-knowledge block (when there is one) as its own leading text part, then images, then the text.
    private static func content(_ m: OutgoingMessage, context: String?) -> [UserContent] {
        (context.map { [UserContent.text($0)] } ?? []) + m.images.map { .image(mediaType: $0.mediaType, base64: $0.base64) } + (m.text.isEmpty && !m.images.isEmpty ? [] : [.text(m.text)])
    }

    /// A blank name is ignored and the old one stays.
    public func rename(_ id: Session.ID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let s = session(id) else { return }
        s.name = allowedName(trimmed, for: id)
        if Self.isReserved(trimmed) { s.transcript.appendNotice(kind: .commandOutput, text: Self.reservedNotice(for: s.name)) }
        persistSessions()
    }

    static func reservedNotice(for chosen: String) -> String {
        "\"Alloy\" is reserved for Alloy's own messages; this session is named \"\(chosen)\""
    }

    /// `name`, or when it is the reserved one a free "Alloy session", "Alloy session 2", ... so `send_message` never
    /// meets two sessions of one name. `id` is the session being renamed, which does not clash with itself.
    func allowedName(_ name: String, for id: UUID?) -> String {
        guard Self.isReserved(name) else { return name }
        let taken = Set(sessions.filter { $0.id != id }.map { AlreadyRead.oneLine($0.name.trimmingCharacters(in: .whitespacesAndNewlines)).lowercased() })
        var candidate = Self.unreserved(name), n = 1
        while taken.contains(candidate.lowercased()) { n += 1; candidate = "\(Messages.reservedName) session \(n)" }
        return candidate
    }

    // MARK: Control

    /// Drops everything still waiting on a session's process: control answers, open prompts and announced changes.
    private func forgetPending(for id: UUID) {
        pendingControls = pendingControls.filter { $0.value.session != id }
        promptInputs = promptInputs.filter { $0.value.session != id }
        overlapIndex.dropProposals(session: id)
    }

    private func sendControl(_ subtype: ControlSubtype, kind: PendingControlKind, via t: any SessionTransport, to s: Session) async {
        let rid = UUID().uuidString.lowercased()
        pendingControls[rid] = (s.id, kind)
        await deliver(.control(requestID: rid, subtype), via: t, to: s)
    }

    private func route(_ result: ControlResult, to kind: PendingControlKind, session s: Session) {
        switch (kind, result) {
        case (.initialize, .success(let body)):
            s.setCommands(InboundDecoder.commands(body["commands"]))
            // The CLI's reported mode is the truth, shown before the first turn's `system/init`.
            if let mode = body["current_permission_mode"]?.stringValue { s.permissionMode = mode }
        case (.initialize, .error(let message, _)):
            report("Could not load Claude's command list: \(message.isEmpty ? "initialize failed" : message)")
        case (.setModel(let requested), .success(let body)):
            let model = body["model"]?.stringValue ?? requested
            s.model = model
            s.transcript.appendNotice(kind: .modelChanged, text: "Model: \(model)")
        case (.setMode, .success):
            // The `status` message that follows carries the new mode and the notice.
            break
        case (.setModel, .error(let message, _)), (.setMode, .error(let message, _)):
            s.transcript.appendNotice(kind: .error, text: message.isEmpty ? "Request failed" : message)
        }
        persistSessions()
    }

    private func persistedState(_ s: Session) -> [String?] {
        [s.hasConversation ? "1" : "0", s.cliSessionID, s.forkSource, s.forkPoint, s.model, s.permissionMode,
         s.slashCommands.map { "\($0.name):\($0.description)" }.joined(separator: "\n")]
    }

    /// Waits until the session's earlier sends have passed the point where they are built and handed on, so a control
    /// typed after a message reaches the CLI after it.
    private func afterEarlierSends(_ id: UUID) async {
        await acquireContext(id)
        releaseContext(id)
    }

    public func setModel(_ model: String, for id: Session.ID) async {
        await afterEarlierSends(id)
        guard !isShuttingDown, let s = session(id) else { return }
        guard let t = live[id]?.transport else { await deferControl(.model(model), for: s); return }
        await sendControl(.setModel(model), kind: .setModel(model), via: t, to: s)
    }

    public func setPermissionMode(_ mode: PermissionMode, for id: Session.ID) async {
        await afterEarlierSends(id)
        guard !isShuttingDown, let s = session(id) else { return }
        guard let t = live[id]?.transport else { await deferControl(.mode(mode), for: s); return }
        await sendControl(.setPermissionMode(mode.rawValue), kind: .setMode(mode.rawValue), via: t, to: s)
    }

    public func answerQuestion(session id: Session.ID, requestID: String, answers: [String: String]) async {
        guard !isShuttingDown, let s = session(id), let t = live[id]?.transport,
              let input = promptInputs[requestID]?.input, pendingPrompt(s, requestID: requestID, plan: false) else { return }
        promptInputs.removeValue(forKey: requestID)
        var updated = input.objectValue ?? [:]
        updated["answers"] = .object(answers.mapValues { .string($0) })
        s.transcript.resolveQuestion(requestID: requestID, answers: answers)
        if s.status == .awaitingPermission, !s.hasPendingPermission { s.status = .working }
        await deliver(.allow(requestID: requestID, updatedInput: .object(updated), updatedPermissions: nil), via: t, to: s)
    }

    public func answerPlan(session id: Session.ID, requestID: String, approve: Bool, modeAfter: PermissionMode,
                           feedback: String?) async {
        guard !isShuttingDown, let s = session(id), let t = live[id]?.transport,
              let input = promptInputs[requestID]?.input, pendingPrompt(s, requestID: requestID, plan: true) else { return }
        promptInputs.removeValue(forKey: requestID)
        let trimmed = feedback?.trimmingCharacters(in: .whitespacesAndNewlines)
        let note = trimmed?.isEmpty == false ? trimmed : nil
        s.transcript.resolvePlan(requestID: requestID, approved: approve, feedback: note)
        if s.status == .awaitingPermission, !s.hasPendingPermission { s.status = .working }
        if approve {
            let mode = JSONValue.object(["type": .string("setMode"), "mode": .string(modeAfter.rawValue),
                                         "destination": .string("session")])
            await deliver(.allow(requestID: requestID, updatedInput: input, updatedPermissions: [mode]), via: t, to: s)
        } else {
            let message = note.map { "Revise: \($0)" } ?? "Revise the plan."
            await deliver(.deny(requestID: requestID, message: message), via: t, to: s)
        }
    }

    private func pendingPrompt(_ s: Session, requestID: String, plan: Bool) -> Bool {
        s.transcript.blocks.contains {
            switch $0 {
            case .question(let q): !plan && q.requestID == requestID && q.state == .pending
            case .plan(let p): plan && p.requestID == requestID && p.state == .pending
            default: false
            }
        }
    }

    /// Starts a dormant (restored) session's process now: `--resume` when it has a conversation, fresh otherwise.
    public func wake(_ id: Session.ID) async {
        guard !isShuttingDown, let s = session(id), s.status == .dormant else { return }
        if let source = s.forkSource {
            // An unsent fork resumes its source; if that conversation is gone the CLI would only fail obscurely.
            let url = TranscriptFile.url(cliSessionID: source, projectRoot: projectRoot, home: home)
            let exists = await Task.detached { FileManager.default.fileExists(atPath: url.path) }.value
            guard s.status == .dormant else { return }
            if !exists {
                failLaunch(s, "Fork source no longer exists")
                return
            }
        }
        s.status = .starting
        await checkForkPoint(s)
        await launch(s, resume: s.hasConversation || s.forkSource != nil, forkFrom: s.forkSource, forkAt: s.forkPoint)
    }

    public func answerPermission(session id: Session.ID, requestID: String, allow: Bool) async {
        guard let s = session(id), let t = live[id]?.transport else { return }
        let pending = s.transcript.blocks.compactMap { b -> JSONValue? in
            if case .permission(let p) = b, p.requestID == requestID, p.state == .pending { return p.input } else { return nil }
        }.last
        guard let input = pending else { return }
        let toolUseID = s.transcript.blocks.compactMap { b -> String? in
            if case .permission(let p) = b, p.requestID == requestID { return p.toolUseID } else { return nil }
        }.last
        permissionAnswered(toolUseID: toolUseID, allow: allow, session: id)
        s.transcript.resolvePermission(requestID: requestID, allowed: allow)
        if s.status == .awaitingPermission, !s.hasPendingPermission { s.status = .working }
        await deliver(allow ? .allow(requestID: requestID, updatedInput: input)
                            : .deny(requestID: requestID, message: "Denied in Alloy"), via: t, to: s)
    }

    public func interrupt(_ id: Session.ID) async {
        guard let s = session(id), let t = live[id]?.transport else { return }
        await deliver(.control(requestID: UUID().uuidString.lowercased(), .interrupt), via: t, to: s)
    }

    public func stop(_ id: Session.ID) async {
        exitedWhileDraining.remove(id)
        deferredControls.removeValue(forKey: id)
        pendingRelaunch.remove(id)
        turnPending.remove(id)
        releaseIdleWaiters(id, reachedIdle: false)
        forgetPending(for: id)
        dropClaims(session: id)
        releaseAwaitingEcho(for: id)
        revokeToken(for: id)
        guard let entry = live.removeValue(forKey: id) else {
            if let s = session(id), s.status == .starting { stoppedDuringLaunch.insert(id); markStopped(s) }
            return
        }
        entry.task.cancel()
        shellWindows.removeValue(forKey: id)
        noteThemeSessionEnded(id)
        await entry.transport.terminate()
        if let s = session(id) {
            s.transcript.finalizeStreaming()
            s.transcript.interruptRunningTools()
            s.transcript.cancelPendingPermissions()
            s.transcript.abandonQueued()
            if case .exited = s.status { return }
            s.status = .exited(status: 0, message: "Stopped")
        }
    }

    /// For window close and quit: stops every session. Live processes get `stopAndWait` (SIGINT, SIGTERM,
    /// SIGKILL, bounded at about 3 s) concurrently, and this returns only once they have exited.
    public func stopAll() async {
        isShuttingDown = true
        warningSleeper?.cancel(); warningSleeper = nil; warningSleeperExpiry = nil
        for id in Array(idleWaiters.keys) { releaseIdleWaiters(id, reachedIdle: false) }
        stopWatching()
        await serverStart?.value
        mcpTokens.removeAll()
        if let server = localServer { await server.stop() }
        localServer = nil
        let entries = live
        live.removeAll()
        for entry in entries.values { entry.task.cancel() }
        // A session still launching stops itself as soon as its process starts.
        for s in sessions where entries[s.id] == nil && s.status == .starting {
            stoppedDuringLaunch.insert(s.id); markStopped(s)
        }
        await withTaskGroup(of: Void.self) { group in
            for entry in entries.values {
                let transport = entry.transport
                group.addTask { await transport.stopAndWait(timeout: .seconds(3)) }
            }
        }
        // Launches in flight see `isShuttingDown` and stop their own transport; wait for them, then sweep up
        // anything that still became live.
        if launchesInFlight > 0 {
            await withCheckedContinuation { launchWaiters.append($0) }
        }
        let late = live
        live.removeAll()
        for entry in late.values { entry.task.cancel() }
        await withTaskGroup(of: Void.self) { group in
            for entry in late.values {
                let transport = entry.transport
                group.addTask { await transport.stopAndWait(timeout: .seconds(3)) }
            }
        }
        for id in Array(entries.keys) + Array(late.keys) {
            noteThemeSessionEnded(id)
            forgetPending(for: id)
            releaseAwaitingEcho(for: id)
            guard let s = session(id) else { continue }
            s.transcript.finalizeStreaming()
            s.transcript.interruptRunningTools()
            s.transcript.cancelPendingPermissions()
            s.transcript.abandonQueued()
            if case .exited = s.status { continue }
            s.status = .exited(status: 0, message: "Stopped")
        }
        await onStop?()
    }

    /// Whether the transport took the message.
    @discardableResult
    private func deliver(_ m: OutboundMessage, via t: any SessionTransport, to s: Session) async -> Bool {
        // Marked before the send: the CLI may begin the turn while the send is still being awaited.
        var isUser = false
        if case .user = m { isUser = true; turnPending.insert(s.id) }
        do { try await t.send(m) } catch {
            if isUser { turnPending.remove(s.id) }
            s.transcript.appendNotice(kind: .error, text: "Could not send to Claude: \(error.localizedDescription)")
            return false
        }
        return true
    }

    /// Empties a session's queue of undelivered messages, releasing what they were going to tell. True if any waited.
    @discardableResult
    private func discardQueue(for id: UUID) -> Bool {
        guard let dropped = queued.removeValue(forKey: id) else { return false }
        for m in dropped { settleTold(m.pending, sent: false) }
        return true
    }

    func session(_ id: Session.ID) -> Session? { sessions.first { $0.id == id } }

    // MARK: Documents and tabs

    public func document(_ path: String) -> EditorDocument? { documents[path] }

    /// Opens `path` in a tab and activates it; an open tab is reused. The file is read off the main actor and
    /// the buffer is built here. `revealLine` (1-based) selects that line; `mode` sets the document's diff mode.
    public func open(_ path: String, revealLine: Int? = nil, mode: DiffMode? = nil) async {
        if !tabs.contains(path) { tabs.append(path) }
        activeTab = path
        if closing.contains(path) { reopened.insert(path) }
        if documents[path] == nil, tabMessages[path] == nil, opening.insert(path).inserted {
            let root = projectRoot.standardizedFileURL.path
            let url = projectRoot.appendingPathComponent(path).standardizedFileURL
            if !url.path.hasPrefix(root + "/") {
                tabMessages[path] = "This file is outside the project."
            } else {
                let result = await Task.detached { Self.readForEditing(url: url) }.value
                if tabs.contains(path) {
                    install(result, path: path, url: url)
                    await reconcileOnOpen(path, result)
                }
            }
            opening.remove(path)
            for waiter in openWaiters.removeValue(forKey: path) ?? [] { waiter.resume() }
        } else if opening.contains(path) {
            // The same file is being read by an earlier call: continue once its document is installed.
            await withCheckedContinuation { openWaiters[path, default: []].append($0) }
        }
        if let doc = documents[path] {
            if let mode { doc.diffMode = mode }
            if let line = revealLine {
                let snap = doc.buffer.snapshot()
                // The empty row after a final newline is not a line of the file.
                let last = snap.lineCount > 1 && snap.lineRange(snap.lineCount - 1).isEmpty ? snap.lineCount - 2 : snap.lineCount - 1
                let row = max(0, min(line - 1, last))
                doc.buffer.select(snap.lineRange(row), reveal: true)
            }
        }
    }

    /// Opens `path` like ``open(_:revealLine:mode:)`` and selects the UTF-8 byte range `range` computes from the loaded
    /// document's snapshot (clamped to the text, once the document is installed; an open of the same path already in
    /// flight is waited for). The range is not snapped to character boundaries. Nothing is selected when the file has no
    /// document.
    public func open(_ path: String, selecting range: (CodeSnapshot) -> Range<Int>) async {
        await open(path)
        guard activeTab == path, let doc = documents[path] else { return }
        let snap = doc.buffer.snapshot()
        let wanted = range(snap)
        let lower = min(max(wanted.lowerBound, 0), snap.utf8Count), upper = min(max(wanted.upperBound, lower), snap.utf8Count)
        doc.buffer.select(lower..<upper, reveal: true)
    }

    func install(_ result: EditorFileRead, path: String, url: URL) {
        switch result {
        case .unreadable: tabMessages[path] = "Can't read \(path)."
        case .binary: tabMessages[path] = "Binary file"
        case .text(let bytes, let stamp, let truncated):
            let buffer = CodeBuffer(utf8: bytes)
            let state: DocState
            if truncated { state = .readOnly(reason: "File is larger than 16 MB") }
            else if buffer.hadInvalidUTF8 { state = .readOnly(reason: "File is not valid UTF-8") }
            else { state = .editable }
            if state != .editable { buffer.isReadOnly = true }
            let ext = (path as NSString).pathExtension.lowercased()
            let doc = EditorDocument(path: path, buffer: buffer, language: ext.isEmpty ? nil : ext,
                                     state: state, diskStamp: stamp)
            documents[path] = doc
            if state == .editable { autosave.watch(doc) { [weak self] d in self?.documents[d.path] === d } }
        }
    }

    /// Closes the tab, saving first when the buffer is dirty. The close is abandoned (tab kept) when the save
    /// fails, when the user typed during the write, or when the file was opened again meanwhile.
    public func close(_ path: String) async {
        guard tabs.contains(path), closing.insert(path).inserted else { return }
        reopened.remove(path)
        defer { closing.remove(path); reopened.remove(path) }
        if let doc = documents[path], doc.isDirty {
            do { try await save(path) } catch { return }
            if doc.isDirty || reopened.contains(path) { return }
        }
        guard let index = tabs.firstIndex(of: path) else { return }
        tabs.remove(at: index)
        documents.removeValue(forKey: path)
        autosave.unwatch(path)
        tabMessages.removeValue(forKey: path)
        syncGeneration.removeValue(forKey: path)
        if activeTab == path { activeTab = tabs.indices.contains(index) ? tabs[index] : tabs.last }
    }

    /// Moves a tab as a drag does: `tabs.insert(tabs.remove(at: from), at: to)`. Out-of-range indexes do nothing.
    public func moveTab(from: Int, to: Int) {
        guard from != to, tabs.indices.contains(from), tabs.indices.contains(to) else { return }
        tabs.insert(tabs.remove(at: from), at: to)
    }

    /// Activates the next (`+1`) or previous (`-1`) tab, wrapping.
    public func cycleTab(_ step: Int) {
        guard !tabs.isEmpty else { return }
        let current = activeTab.flatMap { tabs.firstIndex(of: $0) } ?? (step > 0 ? -1 : 0)
        activeTab = tabs[((current + step) % tabs.count + tabs.count) % tabs.count]
    }

    /// Activates the `number`th tab (1-based); no such tab does nothing.
    public func selectTab(number: Int) {
        guard tabs.indices.contains(number - 1) else { return }
        activeTab = tabs[number - 1]
    }

    // MARK: Saving

    /// Called when focus leaves the code view showing `path` (Task 6 wires it): saves the file.
    public func focusLeft(_ path: String) async { try? await save(path) }

    /// Saves every dirty open document.
    public func saveAll() async {
        for path in tabs { try? await save(path) }
    }

    /// Writes the buffer to disk and records the change as the user's. The write is atomic and keeps the file's
    /// POSIX permissions. If the file changed on disk since Alloy last saw it and the ledger does not know that
    /// text, it is recorded as an `.outside` edit first. A failed write is reported and thrown. Saves of one
    /// file are serialised, and a save of a clean document does nothing.
    public func save(_ path: String) async throws {
        while let running = saving[path] { _ = try? await running.value }
        guard let doc = documents[path], doc.state == .editable, doc.isDirty else { return }
        let task = Task<Void, Error> { @MainActor [weak self] in
            guard let self else { return }
            // Cleared by the task itself, so a waiter that wakes sees the save as finished at once.
            defer { saving.removeValue(forKey: path) }
            try await performSave(doc)
        }
        saving[path] = task
        try await task.value
    }

    private func performSave(_ doc: EditorDocument) async throws {
        ensureLoaded()
        let path = doc.path
        autosave.cancel(path)
        let url = projectRoot.appendingPathComponent(path).standardizedFileURL
        var expected = doc.diskStamp
        defer { saveEpoch[path, default: 0] += 1 }
        // Each pass writes the buffer only if the file is still as Alloy last saw it. If something else wrote it
        // meanwhile (a session edit, another program), that text is merged into the buffer first and the pass
        // repeats, so neither the user's typing nor the other change is overwritten.
        for _ in 0..<4 {
            let snap = doc.buffer.snapshot()
            await closeGate?(path)
            let file = ledger.files[path], expectedStamp = expected
            let outcome: WriteOutcome
            do {
                outcome = try await Task.detached { try Self.write(snap, to: url, expected: expectedStamp, ledger: file) }.value
            } catch {
                report("Can't save \(path): \(error.localizedDescription)")
                throw error
            }
            switch outcome {
            case .changed(let text, let stamp, let known):
                var who: Session?
                if known {
                    // A text the ledger already holds is the last session edit's: name that session in any conflict notice.
                    if case .session(let id)? = ledger.files[path]?.edits.last?.author { who = session(id) }
                } else {
                    let author = saveChangeAuthor(path, stamp.modified)
                    await appendToLedger(path, saved: doc.savedSnapshot, edits: [(author, text)])
                    who = sessionFor(author)
                }
                guard await mergeDisk(Array(text.utf8), into: doc, who: who) else { return }
                expected = stamp
            case .wrote(let text, let stamp):
                writeCount += 1
                // A session edit reached the ledger while the write ran, so the write replaced it on disk. Merge the
                // ledger's text into the buffer and write again, so ledger, buffer and disk end up agreeing.
                if ledger.files[path]?.version != file?.version, let moved = ledger.files[path] {
                    let movedText = await Task.detached { moved.text.text }.value
                    guard await mergeDisk(Array(movedText.utf8), into: doc, who: nil) else { return }
                    expected = stamp
                    continue
                }
                await appendToLedger(path, saved: doc.savedSnapshot, edits: [(.user, text)])
                doc.markSaved(snapshot: snap, stamp: stamp)
                onSaved?(path)
                return
            }
        }
        let message = "\(path) kept changing while it was saved."
        report(message)
        throw NSError(domain: "Alloy", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }

    private enum WriteOutcome: Sendable {
        case wrote(text: String, stamp: FileStamp)
        /// The file's stamp is not the expected one; nothing was written. `known` says the ledger holds that text.
        case changed(text: String, stamp: FileStamp, known: Bool)
    }

    /// Off-main half of a save: replaces the file atomically (temp file, original mode, `rename(2)`) unless its
    /// stamp moved since `expected`. A file that vanished is written anew. The stamp is taken after the write.
    nonisolated private static func write(_ snap: CodeSnapshot, to url: URL, expected: FileStamp,
                                          ledger: FileLedger?) throws -> WriteOutcome {
        let target = url.resolvingSymlinksInPath()
        func moved() -> WriteOutcome? {
            guard let current = stamp(of: target), current != expected else { return nil }
            let text = String(decoding: (try? Data(contentsOf: target)) ?? Data(), as: UTF8.self)
            return .changed(text: text, stamp: current, known: ledger.map { TextDiff.same($0.text.text, text) } ?? false)
        }
        if let changed = moved() { return changed }
        let bytes = snap.utf8(in: 0..<snap.utf8Count)
        // Look once more right before the rename: a write that landed while the temp file was written wins.
        if let changed = try replaceAtomically(Data(bytes), at: target, abortIf: moved) { return changed }
        return .wrote(text: String(decoding: bytes, as: UTF8.self),
                      stamp: stamp(of: target) ?? FileStamp(modified: nil, size: bytes.count))
    }

    /// Replaces `target` with `data`: a temp file beside it, the original's POSIX mode, then `rename(2)`. `abortIf`
    /// is asked once the temp file is written; a non-nil answer removes the temp file, leaves `target` alone and is
    /// returned. Save and the editor's revert both write through this, so neither drops the mode.
    nonisolated private static func replaceAtomically<T>(_ data: Data, at target: URL, abortIf: () -> T?) throws -> T? {
        let mode = (try? FileManager.default.attributesOfItem(atPath: target.path))?[.posixPermissions]
        let temp = target.deletingLastPathComponent().appendingPathComponent(".alloy-save-\(UUID().uuidString)")
        do {
            try data.write(to: temp)
            if let mode { try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: temp.path) }
            if let stop = abortIf() { try? FileManager.default.removeItem(at: temp); return stop }
            guard Darwin.rename(temp.path, target.path) == 0 else {
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno),
                              userInfo: [NSLocalizedDescriptionKey: String(cString: strerror(errno))])
            }
        } catch {
            try? FileManager.default.removeItem(at: temp)
            throw error
        }
        return nil
    }

    /// The default `writeFile`: the mode-keeping atomic replace of a resolved path.
    public nonisolated static func writeKeepingMode(_ data: Data, to target: URL, abortIf: () -> Bool = { false }) throws -> Bool {
        let aborted: Bool? = try replaceAtomically(data, at: target, abortIf: { abortIf() ? true : nil })
        return aborted ?? false
    }

    nonisolated private static func stamp(of url: URL) -> FileStamp? {
        FileStamp.read(url.path)
    }

    /// Records `edits` in the file's ledger (created with `saved` as its baseline), computing the diffs off the
    /// main actor. If the ledger moved meanwhile the edits are applied again on the current state.
    func appendToLedger(_ path: String, saved: CodeSnapshot?, baseline: String? = nil, edits: [(Author, String)]) async {
        let existing = ledger.files[path], date = now()
        let updated = await Task.detached { Self.applying(edits, to: existing, path: path, saved: saved, baseline: baseline, date: date) }.value
        let current = ledger.files[path]
        ledger.files[path] = current?.version == existing?.version && (current == nil) == (existing == nil)
            ? updated : Self.applying(edits, to: current, path: path, saved: saved, baseline: baseline, date: date)
        reindex(path)
        noteFileChanged(path)
        persistLedger()
        if edits.contains(where: { $0.0 == .outside }) { rearmBaselineCheckIfRecent() }
    }

    nonisolated private static func applying(_ edits: [(Author, String)], to existing: FileLedger?, path: String,
                                             saved: CodeSnapshot?, baseline: String?, date: Date) -> FileLedger {
        var f = existing ?? FileLedger(path: path, baseline: baseline
            ?? saved.map { String(decoding: $0.utf8(in: 0..<$0.utf8Count), as: UTF8.self) } ?? "")
        for (author, text) in edits { f.applyFullText(author: author, newText: text, toolUseID: nil, date: date) }
        return f
    }

    /// Merges `bytes`, the file's new text, into `doc`'s unsaved buffer (`DirtyMerge`) and tells the user of any
    /// conflict. Returns false when the document changed under the merge.
    private func mergeDisk(_ bytes: [UInt8], into doc: EditorDocument, who: Session?) async -> Bool {
        let path = doc.path
        // One merge per document at a time; a merge of text the buffer already took in (a second path reached the
        // same disk change) does nothing, so its hunks are not reported as conflicts.
        if !mergeBusy.insert(path).inserted { await withCheckedContinuation { mergeQueue[path, default: []].append($0) } }
        defer {
            if let next = mergeQueue[path]?.first {
                mergeQueue[path]?.removeFirst(); next.resume()
            } else { mergeBusy.remove(path) }
        }
        if doc.lastMergedBytes == bytes { return true }
        let savedVersion = doc.savedVersion, old = doc.savedSnapshot
        let (oldBytes, hunks) = await Task.detached { () -> ([UInt8], [SessionHunk]) in
            let o = old.utf8(in: 0..<old.utf8Count)
            return (o, DirtyMerge.hunks(oldDisk: String(decoding: o, as: UTF8.self),
                                        newDisk: String(decoding: bytes, as: UTF8.self)))
        }.value
        guard documents[path] === doc, doc.savedVersion == savedVersion else { return false }
        let edits = doc.mergeUnreliable ? nil : doc.editsSinceSave()
        let outcome = DirtyMerge.merge(buffer: doc.buffer, savedVersion: savedVersion, hunks: hunks, oldDisk: oldBytes,
                                       userEdits: edits)
        let whose = who.map { "\($0.name)'s edit" } ?? "another change to the file"
        for lines in outcome.conflicts {
            let text = "Your unsaved edit in \(path) overlaps \(whose) at lines \(lines.lowerBound)\u{2013}\(lines.upperBound); your text was kept."
            who?.transcript.appendNotice(kind: .warning, text: text)
            notify(path: path, kind: .warning, text: text)
        }
        doc.lastMergedBytes = bytes
        return true
    }
    static let noticeLimit = 100

    // MARK: Session edits to open files

    /// After a session's tool result the file on disk is new: refresh a clean open document from disk, off the
    /// main actor. A dirty buffer gets the session's change merged in (`DirtyMerge`) and is saved at once. The
    /// read waits for any save of the file in flight and is repeated if one finished meanwhile.
    func syncOpenBuffer(_ path: String, by session: Session?) {
        guard documents[path] != nil else { return }
        let url = projectRoot.appendingPathComponent(path).standardizedFileURL
        syncCounter += 1
        let generation = syncCounter
        syncGeneration[path] = generation
        track { [weak self] in
            await self?.refresh(path, url: url, generation: generation, session: session)
        }
    }

    func readSettled(_ path: String, _ url: URL) async -> EditorFileRead {
        while true {
            while let running = saving[path] { _ = try? await running.value }
            let epoch = saveEpoch[path, default: 0]
            let result = await Task.detached { Self.readForEditing(url: url) }.value
            if saving[path] == nil, saveEpoch[path, default: 0] == epoch { return result }
        }
    }

    private func refresh(_ path: String, url: URL, generation: Int, session: Session?) async {
        defer { if syncTarget[path]?.generation == generation { syncTarget.removeValue(forKey: path) } }
        // Repair invalid UTF-8 the way CodeBuffer(utf8:) does, so the bytes match what a fresh open would hold.
        for attempt in 0..<2 {
            let result = await readSettled(path, url)
            guard syncGeneration[path] == generation, let doc = documents[path] else { return }
            guard case .text(let bytes, let stamp, let truncated) = result else {
                report("Can't refresh \(path) from disk.")
                return
            }
            syncTarget[path] = (generation, bytes)
            if doc.isDirty {
                if await mergeIntoDirty(doc, bytes: bytes, stamp: stamp, generation: generation, session: session) { return }
                if attempt == 1 { report("\(path) changed while merging a session edit; kept the buffer.") }
                continue
            }
            let base = doc.buffer.snapshot()
            await refreshGate?(path, bytes)
            let edit = await Task.detached { Self.replacementEdit(old: base, newBytes: bytes) }.value
            // A newer refresh may have applied while this one computed: drop the older one silently.
            guard syncGeneration[path] == generation else { return }
            guard documents[path] === doc, doc.buffer.version == base.version, !doc.isDirty else {
                if attempt == 1 { report("\(path) changed while refreshing from disk; kept the buffer.") }
                continue
            }
            var readOnly = doc.buffer.isReadOnly
            if truncated, doc.state == .editable {
                doc.state = .readOnly(reason: "File is larger than 16 MB"); readOnly = true
            }
            doc.buffer.isReadOnly = false
            if let edit {
                do { _ = try doc.buffer.applyExternalEdits([edit], expectingVersion: base.version) }
                catch { doc.buffer.isReadOnly = readOnly; report("Can't refresh \(path): \(error)"); return }
            }
            doc.buffer.isReadOnly = readOnly
            doc.markSaved(snapshot: doc.buffer.snapshot(), stamp: stamp)
            // The ledger follows the disk: a change it was never told about becomes an `.outside` edit.
            if !truncated, doc.state == .editable, let file = ledger.files[path] {
                let text = String(decoding: bytes, as: UTF8.self)
                let differs = await Task.detached { !TextDiff.same(file.text.text, text) }.value
                if differs, ledger.files[path]?.version == file.version {
                    await appendToLedger(path, saved: doc.savedSnapshot, edits: [(saveChangeAuthor(path, stamp.modified), text)])
                }
            }
            return
        }
    }

    /// Merges a session's write into a buffer with unsaved typing, then saves. Returns false when the document
    /// changed under the merge and the caller should look again; true when the refresh is settled.
    private func mergeIntoDirty(_ doc: EditorDocument, bytes: [UInt8], stamp: FileStamp, generation: Int, session: Session?) async -> Bool {
        let path = doc.path
        await refreshGate?(path, bytes)
        guard syncGeneration[path] == generation else { return true }
        guard doc.isDirty else { return false }
        guard await mergeDisk(bytes, into: doc, who: session) else { return false }
        guard syncGeneration[path] == generation else { return true }
        // The buffer now holds this disk text, so the save must not treat it as a change to merge again.
        doc.diskStamp = stamp
        // If this save fails the disk holds text the buffer cannot be diffed against again: keep all user text.
        do { try await save(path) } catch { doc.mergeUnreliable = true }
        return true
    }

    /// The single edit turning `old` into `newBytes`: common prefix and suffix are trimmed back to scalar
    /// boundaries. O(n), so it is cheap enough to run off main for any size.
    nonisolated static func replacementEdit(old: CodeSnapshot, newBytes: [UInt8]) -> CodeTextEdit? {
        let a = old.utf8(in: 0..<old.utf8Count)
        let b = Array(String(decoding: newBytes, as: UTF8.self).utf8)
        if a == b { return nil }
        let m = min(a.count, b.count)
        var p = 0
        while p < m && a[p] == b[p] { p += 1 }
        while p > 0 && ((p < a.count && a[p] & 0xC0 == 0x80) || (p < b.count && b[p] & 0xC0 == 0x80)) { p -= 1 }
        var sfx = 0
        while sfx < m - p && a[a.count - 1 - sfx] == b[b.count - 1 - sfx] { sfx += 1 }
        while sfx > 0 && (a[a.count - sfx] & 0xC0 == 0x80 || b[b.count - sfx] & 0xC0 == 0x80) { sfx -= 1 }
        return CodeTextEdit(range: p..<(a.count - sfx), text: String(decoding: b[p..<(b.count - sfx)], as: UTF8.self))
    }

    /// Reads a file for editing: stats it, rejects binary, and reads at most `previewLimit` bytes.
    nonisolated static func readForEditing(url: URL) -> EditorFileRead {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let handle = try? FileHandle(forReadingFrom: url) else { return .unreadable }
        defer { try? handle.close() }
        let size = (attrs[.size] as? Int) ?? -1
        // From the open handle, not the path: a file replaced after the open must not give the old bytes the new stamp.
        let stamp = FileStamp.read(descriptor: handle.fileDescriptor) ?? FileStamp(modified: attrs[.modificationDate] as? Date, size: size)
        // Read straight into the array that becomes the buffer's input. `FileHandle.read` returns an autoreleased
        // `Data`, which a pool-less background thread keeps alive (a second 2 MB copy of a large file), and
        // `[UInt8](data)` would then copy it again.
        guard var data = readBytes(descriptor: handle.fileDescriptor, upTo: previewLimit + 1, sizeHint: size) else { return .unreadable }
        if data.prefix(8192).contains(0) { return .binary }
        let truncated = data.count > previewLimit
        if truncated {
            data.removeSubrange(previewLimit...)
            // Cut back to a scalar boundary so the cut does not read as invalid UTF-8.
            var end = data.count, back = 0
            while end > 0, back < 4, data[end - 1] & 0xC0 == 0x80 { end -= 1; back += 1 }
            if end > 0, back < 4 {
                let lead = data[end - 1]
                let need = lead >= 0xF0 ? 4 : lead >= 0xE0 ? 3 : lead >= 0xC0 ? 2 : 1
                if need > back + 1 { end -= 1 }
            }
            data.removeSubrange(end...)
        }
        return .text(data, stamp, truncated: truncated)
    }

    /// Up to `limit` bytes from the current position of `descriptor`, in one allocation sized from `sizeHint`
    /// (the file size, when known); nil when a read fails.
    nonisolated private static func readBytes(descriptor: Int32, upTo limit: Int, sizeHint: Int) -> [UInt8]? {
        let first = max(1, min(limit, sizeHint >= 0 ? sizeHint + 1 : 65_536))
        var failed = false
        var out = [UInt8](unsafeUninitializedCapacity: first) { buffer, count in
            count = 0
            while count < first {
                let r = read(descriptor, buffer.baseAddress! + count, first - count)
                if r < 0 { if errno == EINTR { continue }; failed = true; return }
                if r == 0 { return }
                count += r
            }
        }
        if failed { return nil }
        // The file grew past its size hint: take the rest in chunks.
        if out.count == first, first < limit {
            var chunk = [UInt8](repeating: 0, count: 65_536)
            while out.count < limit {
                let r = read(descriptor, &chunk, min(chunk.count, limit - out.count))
                if r < 0 { if errno == EINTR { continue }; return nil }
                if r == 0 { break }
                out.append(contentsOf: chunk[0..<r])
            }
        }
        return out
    }

    // MARK: File panel content

    /// Largest file the editor opens; a bigger one is cut off and read-only.
    public nonisolated static let previewLimit = 16 * 1024 * 1024

    // MARK: Ledger actions

    /// The file's full diff, memoised by the ledger's version.
    public func diffLines(path: String) -> [DiffLine] {
        guard let file = ledger.files[path] else { return [] }
        let v = file.version
        if let hit = diffCache[path], hit.version == v { return hit.lines }
        diffComputations += 1
        let lines = file.diffLines()
        diffCache[path] = (v, lines)
        return lines
    }

    public func editRecord(id: UUID) -> EditRecord? { recordIndex[id] }

    /// `detectTug` is false when the ledger was just loaded: old edits are not new activity.
    private func reindex(_ path: String, detectTug: Bool = true) {
        for r in ledger.files[path]?.edits ?? [] { recordIndex[r.id] = r }
        if detectTug { scanTugOfWar(path) } else { markTugSeen(path) }
        refreshOverlapWarnings(path)
    }

    public func keep(edit: UUID, path: String) {
        ensureLoaded()
        guard ledger.files[path] != nil else { return }
        ledger.files[path]!.keep(edit)
        reindex(path)
        revertConflicts[edit] = nil
        persistLedger()
    }

    /// Keeps every live edit of `path` (its text was committed), and persists.
    func keepAllEdits(path: String) {
        guard ledger.files[path] != nil else { return }
        ledger.files[path]!.keepAll { _ in true }
        for r in ledger.files[path]!.edits { revertConflicts[r.id] = nil }
        reindex(path)
        persistLedger()
    }

    public func revert(edit: UUID, path: String) async -> RevertOutcome {
        let outcome = await performRevert(edit: edit, path: path)
        reindex(path)
        switch outcome {
        case .reverted: revertConflicts[edit] = nil
        case .conflict(let reason): revertConflicts[edit] = reason
        }
        return outcome
    }

    private func authorName(_ author: Author) -> String? {
        guard case .session(let id) = author else { return nil }
        return session(id)?.name
    }

    /// What the off-main half of a revert found and computed.
    private struct RevertWork: Sendable {
        /// A conflict reached before any ledger change (the file is gone, unreadable or not UTF-8).
        var early: RevertOutcome?
        var outcome: RevertOutcome = .conflict(reason: "")
        /// The stamp of the file the disk text was read from; the write is abandoned if the file's stamp differs.
        var stamp: FileStamp?
        /// The ledger with the disk's unseen changes recorded as an outside edit; nil when the disk matched.
        var afterOutside: FileLedger?
        /// The ledger after the revert; nil unless the revert succeeded.
        var reverted: FileLedger?
    }

    /// Reads the file, records unseen disk changes as an outside edit and reverts, all on a copy of the ledger.
    /// Whole-file reads, diffs and the revert itself run here, off the main actor.
    nonisolated private static func revertWork(file original: FileLedger, edit: UUID, target: URL, outsideAuthor: Author,
                                               names: [Author: String], date: Date,
                                               gate: (@Sendable (String) async -> Void)?) async -> RevertWork {
        var file = original
        let handle = try? FileHandle(forReadingFrom: target)
        defer { try? handle?.close() }
        let readStamp = handle.flatMap { FileStamp.read(descriptor: $0.fileDescriptor) }
        guard let handle, let disk = try? handle.readToEnd() ?? Data() else {
            return RevertWork(early: .conflict(reason: FileManager.default.fileExists(atPath: target.path)
                                               ? "Could not read \(original.path)." : "File was deleted outside Alloy"))
        }
        var work = RevertWork()
        work.stamp = readStamp
        await gate?(original.path)
        if disk != Data(file.text.text.utf8) {
            guard let diskText = String(data: disk, encoding: .utf8) else {
                return RevertWork(early: .conflict(reason: "File is not UTF-8 text"))
            }
            if file.applyFullText(author: outsideAuthor, newText: diskText, toolUseID: nil, date: date) != nil {
                work.afterOutside = file
            }
        }
        work.outcome = file.revert(edit, date: date, authorName: { names[$0] })
        if case .reverted = work.outcome { work.reverted = file }
        return work
    }

    /// Runs inside the path's save slot (`saving`), so no save of this file lands between the revert's read and its
    /// write, and a save queued meanwhile runs after it and merges the reverted text with any typing.
    private func performRevert(edit: UUID, path: String) async -> RevertOutcome {
        while let running = saving[path] { _ = try? await running.value }
        let task = Task<RevertOutcome, Never> { @MainActor [weak self] in
            guard let self else { return .conflict(reason: "Alloy is closing.") }
            defer { saving.removeValue(forKey: path); saveEpoch[path, default: 0] += 1 }
            return await revertInSlot(edit: edit, path: path)
        }
        saving[path] = Task<Void, Error> { _ = await task.value }
        return await task.value
    }

    private func revertInSlot(edit: UUID, path: String) async -> RevertOutcome {
        ensureLoaded()
        // Resolve symlinks first and write to the resolved path, which must still be inside the project.
        let rootPath = projectRoot.resolvingSymlinksInPath().path
        let lexical = projectRoot.appendingPathComponent(path).standardizedFileURL
        let target = lexical.resolvingSymlinksInPath()
        let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        let lexicalRoot = projectRoot.standardizedFileURL.path
        for _ in 0..<3 {
            guard let file = ledger.files[path] else { return .conflict(reason: "Unknown file.") }
            guard lexical.path.hasPrefix(lexicalRoot.hasSuffix("/") ? lexicalRoot : lexicalRoot + "/"),
                  target.path.hasPrefix(prefix) else {
                return .conflict(reason: "The file is outside the project.")
            }
            // Main-actor facts the off-main work needs: who an unseen disk change is attributed to, and session names.
            let mtime = (try? FileManager.default.attributesOfItem(atPath: target.path))?[.modificationDate] as? Date
            let outsideAuthor = saveChangeAuthor(path, mtime)
            var names: [Author: String] = [:]
            for e in file.edits { if let n = authorName(e.author) { names[e.author] = n } }
            let date = now()
            let gate = revertGate
            let work = await Task.detached { await Self.revertWork(file: file, edit: edit, target: target, outsideAuthor: outsideAuthor,
                                                                   names: names, date: date, gate: gate) }.value
            // A session edit reached the ledger meanwhile: look again on the current state.
            guard ledger.files[path]?.version == file.version else { continue }
            if let early = work.early { return early }
            // Changes made outside Alloy since the ledger last saw the file become an `.outside` edit first,
            // so the revert can never write over them.
            func commitOutside() {
                if let after = work.afterOutside, ledger.files[path]?.version == file.version {
                    ledger.files[path] = after; persistLedger()
                }
            }
            guard let reverted = work.reverted, case .reverted(let newText) = work.outcome else {
                commitOutside(); return work.outcome
            }
            let writer = writeFile, writeGate = revertWriteGate
            let expectedStamp = work.stamp
            let moved: Bool
            do {
                moved = try await Task.detached {
                    await writeGate?(path)
                    return try writer(Data(newText.utf8), target, { FileStamp.read(target.path) != expectedStamp })
                }.value
            } catch {
                commitOutside()
                return .conflict(reason: "Could not write \(path): \(error.localizedDescription)")
            }
            // The file changed since the revert read it (something wrote it meanwhile): nothing was written. Read it
            // again and recompute against the current text, which also reports a conflict if the edit no longer reverts.
            if moved { continue }
            guard ledger.files[path]?.version == file.version else {
                // The ledger moved while the file was written: the disk now holds the reverted text, so record it.
                await appendToLedger(path, saved: nil, edits: [(.outside, newText)])
                return .conflict(reason: "\(path) changed while it was reverted.")
            }
            ledger.files[path] = reverted
            persistLedger()
            return work.outcome
        }
        return .conflict(reason: "\(path) kept changing while it was reverted.")
    }

    // MARK: Persistence

    private var ledgerURL: URL { ProjectLedger.storeURL(projectRoot: projectRoot, appSupport: appSupport) }
    var notesURL: URL { storeDirectory.appendingPathComponent("notes.json") }
    var storeDirectory: URL { ledgerURL.deletingLastPathComponent() }
    var readsURL: URL { storeDirectory.appendingPathComponent("reads.json") }
    private var sessionsURL: URL { storeDirectory.appendingPathComponent("sessions.json") }

    func report(_ message: String) { errors.append(message) }

    /// Loads persisted state once, on first use. A corrupt file is moved aside and reported, never overwritten.
    private func ensureLoaded() {
        guard !loaded else { return }
        loaded = true
        if let l = loadFile(ledgerURL, { try JSONDecoder().decode(ProjectLedger.self, from: $0) }) { ledger = l; for p in l.files.keys { reindex(p, detectTug: false); overlapIndex.invalidate(path: p) } }
        if let r = loadFile(sessionsURL, { try JSONDecoder().decode([SessionRecord].self, from: $0) }) { records = r }
        if let g = loadFile(generationsURL, { try JSONDecoder().decode([String: Int].self, from: $0) }) {
            generationsSnapshot = g
            for (k, v) in g { if let id = UUID(uuidString: k) { compactionGeneration[id] = v } }
        }
        loadKnowledge()
        if let t = loadFile(toldURL, { try JSONDecoder().decode([String: [String: ToldEntry]].self, from: $0) }) {
            for (k, v) in t { if let id = UUID(uuidString: k) { told[id] = v } }
        }
        if let c = loadFile(claimsURL, { try JSONDecoder().decode([Claim].self, from: $0) }) { claims = c }
        if let t = loadFile(overlapToldURL, { try JSONDecoder().decode([String: [String: Int]].self, from: $0) }) {
            for (k, v) in t { if let id = UUID(uuidString: k) { overlapTold[id] = v } }
            pruneOverlapTold()
        }
    }

    func loadFile<T>(_ url: URL, _ decode: (Data) throws -> T) -> T? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        do { return try decode(Data(contentsOf: url)) } catch {
            var dest = url.deletingLastPathComponent()
                .appendingPathComponent("\(url.lastPathComponent).corrupt-\(Int(now().timeIntervalSince1970))")
            if FileManager.default.fileExists(atPath: dest.path) {
                dest = dest.deletingLastPathComponent()
                    .appendingPathComponent("\(dest.lastPathComponent)-\(UUID().uuidString.prefix(8))")
            }
            do {
                try FileManager.default.moveItem(at: url, to: dest)
                report("\(url.lastPathComponent) was unreadable and was moved to \(dest.lastPathComponent).")
            } catch {
                report("\(url.lastPathComponent) is unreadable and could not be moved aside: \(error.localizedDescription)")
            }
            return nil
        }
    }

    /// Writes a snapshot of the ledger off the main actor. Writes run one after another, so an older snapshot never
    /// lands after a newer one.
    private func persistLedger() {
        let snapshot = ledger, url = ledgerURL, previous = ledgerWrite
        ledgerWrite = Task.detached { [weak self] in
            await previous?.value
            do { try snapshot.save(to: url) } catch {
                let message = "Could not save edit history: \(error.localizedDescription)"
                await self?.report(message)
            }
        }
    }

    private func persistSessions() {
        for s in sessions {
            let r = SessionRecord(id: s.id, name: s.name, colorIndex: s.colorIndex, hasConversation: s.hasConversation,
                                  cliSessionID: s.cliSessionID, model: s.model, permissionMode: s.permissionMode,
                                  slashCommands: s.slashCommands.isEmpty ? nil : s.slashCommands, forkSource: s.forkSource, forkPoint: s.forkPoint,
                                  purpose: s.purpose == .coding ? nil : s.purpose)
            if let i = records.firstIndex(where: { $0.id == s.id }) { records[i] = r } else { records.append(r) }
        }
        do {
            try FileManager.default.createDirectory(at: storeDirectory, withIntermediateDirectories: true)
            try JSONEncoder().encode(records).write(to: sessionsURL, options: .atomic)
        } catch { report("Could not save sessions: \(error.localizedDescription)") }
    }

    /// Shows a restored session's earlier history, read from the CLI's transcript file. Runs once per session and
    /// never launches the process: the file is parsed off the main actor, then replayed on it.
    public func loadHistory(_ id: Session.ID) async {
        if let running = historyLoads[id] { await running.value; return }
        guard historyPending.remove(id) != nil, session(id) != nil else { return }
        let task = Task { await self.replayHistory(id) }
        historyLoads[id] = task
        await task.value
    }

    private static let historyLimit = 2000

    private func replayHistory(_ id: Session.ID) async {
        guard let s = session(id) else { return }
        // An unsent fork has no file of its own yet: it shows its source's conversation.
        // In the run that made the fork this stays true after its first turn, whose lines are already in the chat
        // (the fork's own file would repeat them).
        let historySource = forkHistorySource[s.id] ?? s.forkSource
        // The fork's chat ends where the fork starts, however far its source has moved on since.
        let historyPoint = historySource == nil ? nil : (forkHistoryPoint[s.id] ?? s.forkPoint)
        let forked = historySource != nil
        let url = TranscriptFile.url(cliSessionID: historySource ?? s.cliSessionID, projectRoot: projectRoot, home: home)
        let root = projectRoot, limit = Self.historyLimit
        // Read, parse and replay all off the main actor; only the last blocks come back.
        let replayed = await Task.detached { () -> (blocks: [ChatBlock], skippedLines: Int)? in
            guard var data = try? Data(contentsOf: url) else { return nil }
            if let historyPoint, let cut = TranscriptFile.truncated(data, after: historyPoint) { data = cut }
            var replay = Transcript(projectRoot: root)
            let skipped = TranscriptFile.forEachMessage(in: data) { replay.apply($0, now: $1) }
            replay.finishReplay()
            return (Array(replay.blocks.suffix(limit)), skipped)
        }.value
        guard let s = session(id) else { return }
        guard let replayed else {
            s.transcript.prepend(history: [.notice(id: UUID(), kind: .history,
                                                   text: forked ? "Fork source no longer exists" : "No earlier history found")])
            return
        }
        var blocks = reattachEdits(to: replayed.blocks).map(Self.historyBlock)
        if replayed.skippedLines > 0 {
            let n = replayed.skippedLines
            blocks.insert(.notice(id: UUID(), kind: .history,
                                  text: "\(n) \(n == 1 ? "line" : "lines") of history could not be read"), at: 0)
        }
        s.transcript.prepend(history: blocks)
    }

    /// Matches the ledger's edits to replayed tool blocks by tool-use id, so their diffs show in the chat again.
    private func reattachEdits(to blocks: [ChatBlock]) -> [ChatBlock] {
        var byTool: [String: [EditRecord]] = [:]
        for file in ledger.files.values {
            for rec in file.edits { if let t = rec.toolUseID { byTool[t, default: []].append(rec) } }
        }
        guard !byTool.isEmpty else { return blocks }
        return blocks.map { block in
            guard case .tool(var t) = block, let recs = byTool[t.toolUseID] else { return block }
            t.editIDs.append(contentsOf: recs.map(\.id))
            for rec in recs where editDiffs[rec.id] == nil {
                editDiffs[rec.id] = DiffSlice.visible(diffLines(path: rec.path), editIDs: [rec.id])
            }
            return .tool(t)
        }
    }

    /// Replayed text and thinking ids ("m1#0") would collide with the live transcript's own counter.
    private static func historyBlock(_ b: ChatBlock) -> ChatBlock {
        switch b {
        case .assistantText(let id, let text): .assistantText(id: "h-" + id, text: text)
        case .thinking(let id, let text, let n): .thinking(id: "h-" + id, text: text, estimatedTokens: n)
        default: b
        }
    }

    public func restore() async {
        ensureLoaded()
        guard !restored else { return }
        restored = true
        await startServer()
        var renamedOnRestore = false
        for r in records where session(r.id) == nil {
            let s = Session(id: r.id, name: r.name, colorIndex: r.colorIndex, projectRoot: projectRoot,
                            hasConversation: r.hasConversation, cliSessionID: r.cliSessionID,
                            model: r.model, permissionMode: r.permissionMode, forkSource: r.forkSource, forkPoint: r.forkPoint,
                            purpose: r.purpose ?? .coding)
            s.status = .dormant
            // A name saved before "Alloy" was reserved.
            if Self.isReserved(r.name) {
                s.name = allowedName(r.name, for: r.id)
                s.transcript.appendNotice(kind: .commandOutput, text: Self.reservedNotice(for: s.name))
                renamedOnRestore = true
            }
            if let commands = r.slashCommands { s.restoreCommands(commands) }
            if r.hasConversation { historyPending.insert(r.id) }
            sessions.append(s)
            if selectedSessionID == nil { selectedSessionID = s.id }
        }
        if renamedOnRestore { persistSessions() }
        // Commits made while Alloy was closed: files the ledger still shows as changed may now equal HEAD.
        track { [weak self] in await self?.checkGitBaselines() }
    }
}

/// A message about the user's work in one file (or none), for the UI to show.
public struct Notice: Equatable, Sendable {
    /// The project-relative path it is about, nil for a message about no one file.
    public var path: String?
    public var kind: NoticeKind
    public var text: String
    public init(path: String?, kind: NoticeKind, text: String) { self.path = path; self.kind = kind; self.text = text }
}

public struct FileStamp: Equatable, Sendable, Codable {
    public var modified: Date?
    public var size: Int
    public init(modified: Date?, size: Int) { self.modified = modified; self.size = size }

    /// Also part of equality: a file replaced or rewritten by `cp -p`, `touch -r` or `rsync -a` can keep its size
    /// and modification date, but not its inode (a replacement) or change time (an in-place write).
    public var inode: UInt64 = 0
    public var changed: Date?

    public init(modified: Date?, size: Int, inode: UInt64 = 0, changed: Date? = nil) {
        self.modified = modified; self.size = size; self.inode = inode; self.changed = changed
    }

    /// The stamp of the file at `path` (following symlinks), or nil when it cannot be examined.
    public static func read(_ path: String) -> FileStamp? {
        var st = stat()
        guard stat(path, &st) == 0 else { return nil }
        return FileStamp(st)
    }

    /// The stamp of the file an open descriptor refers to, even if the path has since been replaced.
    public static func read(descriptor: Int32) -> FileStamp? {
        var st = stat()
        guard fstat(descriptor, &st) == 0 else { return nil }
        return FileStamp(st)
    }

    private init(_ st: stat) {
        func date(_ t: timespec) -> Date { Date(timeIntervalSince1970: TimeInterval(t.tv_sec) + TimeInterval(t.tv_nsec) / 1e9) }
        self.init(modified: date(st.st_mtimespec), size: Int(st.st_size), inode: UInt64(st.st_ino),
                  changed: date(st.st_ctimespec))
    }
}

public enum PermissionMode: String, CaseIterable, Sendable {
    case default_ = "default", acceptEdits, plan, auto, dontAsk

    public var displayName: String {
        switch self {
        case .default_: "Default"
        case .acceptEdits: "Accept edits"
        case .plan: "Plan"
        case .auto: "Auto"
        case .dontAsk: "Don't ask"
        }
    }
}

public struct ImageAttachment: Sendable, Equatable, Identifiable {
    public var id: UUID
    public var mediaType: String
    public var base64: String
    public var pixelSize: (Int, Int)?
    public var byteCount: Int

    public init(id: UUID = UUID(), mediaType: String, base64: String, pixelSize: (Int, Int)? = nil, byteCount: Int) {
        self.id = id; self.mediaType = mediaType; self.base64 = base64
        self.pixelSize = pixelSize; self.byteCount = byteCount
    }

    public static func == (a: ImageAttachment, b: ImageAttachment) -> Bool {
        a.id == b.id && a.mediaType == b.mediaType && a.byteCount == b.byteCount
    }
}

public struct OutgoingMessage: Sendable, Equatable {
    public var text: String
    public var images: [ImageAttachment]
    public var priority: Priority?
    /// Set for a message from another session or from Alloy: it shows as a session-message row and gets no
    /// "already read" block.
    var origin: SessionMessageOrigin?
    /// The id the message goes out under (the CLI echoes it); nil lets `send` pick one.
    var uuid: UUID?

    public init(text: String, images: [ImageAttachment] = [], priority: Priority? = nil) {
        self.text = text; self.images = images; self.priority = priority
    }

    init(text: String, priority: Priority?, origin: SessionMessageOrigin) {
        self.text = text; self.images = []; self.priority = priority; self.origin = origin
    }
}

enum EditorFileRead: Sendable {
    case unreadable, binary
    case text([UInt8], FileStamp, truncated: Bool)
}
