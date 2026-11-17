#if !os(Windows)

import Dispatch
import Foundation
import MetalUITerminal

/// One pane's pty plus its emulator. The emulator is touched only on `readerQueue`, which every pane shares;
/// the reader always reads, so a hidden pane never stalls its shell.
public final class TerminalSession: @unchecked Sendable {
    /// One shared serial queue for every pane.
    public static let readerQueue = DispatchQueue(label: "alloy.terminal.reader", qos: .userInitiated)
    /// Bytes per read.
    public static let readBudget = 64 * 1024
    /// Bytes per wakeup; the rest waits for the next one so other panes interleave.
    public static let wakeupBudget = 1024 * 1024

    /// All invoked on the main actor, coalesced.
    public struct Callbacks: Sendable {
        public var onTitle: @MainActor @Sendable (String) -> Void
        public var onWorkingDirectory: @MainActor @Sendable (String) -> Void
        /// `exited(n)` is `n`, `signaled(s)` is `128 + s`.
        public var onExit: @MainActor @Sendable (Int32) -> Void

        public init(onTitle: @escaping @MainActor @Sendable (String) -> Void = { _ in },
                    onWorkingDirectory: @escaping @MainActor @Sendable (String) -> Void = { _ in },
                    onExit: @escaping @MainActor @Sendable (Int32) -> Void = { _ in }) {
            self.onTitle = onTitle
            self.onWorkingDirectory = onWorkingDirectory
            self.onExit = onExit
        }
    }

    public let paneID: UUID
    let pty: any PtyHandle
    let now: @Sendable () -> Date
    private let emulator: TerminalEmulator   // readerQueue only
    private let readBuffer = UnsafeMutableRawBufferPointer.allocate(byteCount: TerminalSession.readBudget, alignment: 16)   // readerQueue only
    private let state = NSLock()
    private var callbacks: Callbacks?
    private var version: UInt64 = 0
    private var outputHook: (@Sendable () -> Void)?
    private var pendingTitle: String?
    private var pendingDirectory: String?
    private var deliveryScheduled = false
    private var exitDelivered = false
    private var started = false
    private var lastOutput: Date?
    private var currentSize: TerminalSize
    private var pendingResize: TerminalSize?
    private var exited = false

    public init(paneID: UUID, pty: any PtyHandle, size: TerminalSize, scrollback: Int,
                now: @escaping @Sendable () -> Date = Date.init) {
        self.paneID = paneID
        self.pty = pty
        self.now = now
        self.currentSize = size
        self.emulator = TerminalEmulator(cols: size.cols, rows: size.rows, scrollback: scrollback)
    }

    deinit {
        pty.close()
        readBuffer.deallocate()
    }

    /// Bumped once per wakeup that fed bytes.
    public var outputVersion: UInt64 { state.withLock { version } }

    /// Called on the reader queue, at most once per wakeup.
    public var onOutput: (@Sendable () -> Void)? {
        get { state.withLock { outputHook } }
        set { state.withLock { outputHook = newValue } }
    }

    /// When output last arrived, for busy detection on platforms without a foreground group.
    var lastOutputTime: Date? { state.withLock { lastOutput } }

    public func start(_ callbacks: Callbacks) {
        let first = state.withLock { () -> Bool in
            if started { return false }
            started = true
            self.callbacks = callbacks
            return true
        }
        guard first else { return }
        pty.onReadable(queue: Self.readerQueue) { [weak self] in self?.wakeup() }
        let pty = self.pty
        Task.detached { [weak self] in
            let status = await pty.exitStatus
            guard let self else { return }
            self.state.withLock { self.exited = true }
            Self.readerQueue.async { self.finishExit(status) }
        }
    }

    public func write(_ bytes: [UInt8]) {
        guard !bytes.isEmpty else { return }
        pty.write(bytes)
    }

    /// Runs `body` on the reader queue, where the emulator lives.
    public func withEmulator<T: Sendable>(_ body: @escaping @Sendable (TerminalEmulator) -> T) async -> T {
        await withCheckedContinuation { continuation in
            Self.readerQueue.async { continuation.resume(returning: body(self.emulator)) }
        }
    }

    /// Dispatches emulator events; internal, for tests.
    func apply(_ events: [TerminalEvent]) {
        var scheduleNeeded = false
        for event in events {
            switch event {
            case .reply(let bytes):
                pty.write(bytes)
            case .title(let text):
                state.withLock { pendingTitle = text }
                scheduleNeeded = true
            case .workingDirectory(let url):
                state.withLock { pendingDirectory = url.path }
                scheduleNeeded = true
            case .bell, .hyperlink:
                break
            }
        }
        if scheduleNeeded { scheduleDelivery() }
    }

    // MARK: Resize, busy, termination

    /// The last size applied to the pty. The emulator keeps its spawn size until MetalUI lands reflow.
    public var size: TerminalSize { state.withLock { currentSize } }

    public var processID: Int32 { pty.processID }

    /// True once the shell's exit is known; no signal is sent after that.
    public var hasExited: Bool { state.withLock { exited } }

    /// Clamps to 2 x 1 and coalesces: the newest pending request replaces older ones.
    public func resize(cols: Int, rows: Int) {
        let request = TerminalSize(cols: max(2, cols), rows: max(1, rows))
        let schedule = state.withLock { () -> Bool in
            let had = pendingResize != nil
            pendingResize = request
            return !had
        }
        guard schedule else { return }
        Self.readerQueue.async { [self] in
            let latest = state.withLock { () -> TerminalSize? in
                defer { pendingResize = nil }
                return pendingResize
            }
            guard let latest, !hasExited else { return }
            pty.resize(cols: latest.cols, rows: latest.rows)
            state.withLock { currentSize = latest }
        }
    }

    /// On demand only, never polled.
    public func isBusy() -> Bool {
        if hasExited { return false }
        if let group = pty.foregroundProcessGroup() { return group != processID }
        guard let last = lastOutputTime else { return false }
        return now().timeIntervalSince(last) < 5
    }

    /// SIGHUP to the group, wait up to `grace`, then SIGKILL, reap and close. Idempotent; no signal after exit.
    public func terminate(grace: Duration) async {
        if !hasExited {
            pty.signalGroup(.hangup)
            let pty = self.pty
            // Unstructured race: the pty's exit wait cannot be cancelled, so a task group would wait for it.
            let reaped = await withCheckedContinuation { (c: CheckedContinuation<Bool, Never>) in
                let once = OnceResume(c)
                Task.detached { _ = await pty.exitStatus; once.resume(true) }
                Task.detached { try? await Task.sleep(for: grace); once.resume(false) }
            }
            if !reaped && !hasExited {
                pty.signalGroup(.kill)
                _ = await pty.exitStatus
            }
            state.withLock { exited = true }
        }
        // Let a pending exit drain run before the pty goes away.
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            Self.readerQueue.async { c.resume() }
        }
        pty.close()
    }

    /// Closes the pty without signalling (after exit).
    public func close() { pty.close() }

    // MARK: Reading (reader queue)

    private func wakeup() {
        var consumed = 0
        var fed = false
        var more = false
        while true {
            let n = pty.read(into: readBuffer)
            if n <= 0 { break }
            emulator.feed(UnsafeRawBufferPointer(rebasing: readBuffer[..<n]))
            fed = true
            consumed += n
            if consumed >= Self.wakeupBudget { more = true; break }
        }
        if fed { didFeed() }
        if more { Self.readerQueue.async { [weak self] in self?.wakeup() } }
    }

    private func didFeed() {
        apply(emulator.drainEvents())
        let hook = state.withLock { () -> (@Sendable () -> Void)? in
            version &+= 1
            lastOutput = now()
            return outputHook
        }
        hook?()
    }

    /// Runs on the reader queue after the pty reported its exit: drain to end of file, then report once.
    private func finishExit(_ status: PseudoTerminal.ExitStatus) {
        var fed = false
        while true {
            let n = pty.read(into: readBuffer)
            if n <= 0 { break }
            emulator.feed(UnsafeRawBufferPointer(rebasing: readBuffer[..<n]))
            fed = true
        }
        if fed { didFeed() }
        let code: Int32
        switch status {
        case .exited(let n): code = n
        case .signaled(let s): code = 128 + s
        }
        let target = state.withLock { () -> Callbacks? in
            if exitDelivered { return nil }
            exitDelivered = true
            return callbacks
        }
        guard let target else { return }
        Task { @MainActor in target.onExit(code) }
    }

    // MARK: Coalesced delivery

    private func scheduleDelivery() {
        let schedule = state.withLock { () -> Bool in
            if deliveryScheduled { return false }
            deliveryScheduled = true
            return true
        }
        guard schedule else { return }
        Task { @MainActor [weak self] in self?.deliver() }
    }

    @MainActor private func deliver() {
        let (title, directory, target) = state.withLock { () -> (String?, String?, Callbacks?) in
            deliveryScheduled = false
            defer { pendingTitle = nil; pendingDirectory = nil }
            return (pendingTitle, pendingDirectory, callbacks)
        }
        guard let target else { return }
        if let title { target.onTitle(title) }
        if let directory { target.onWorkingDirectory(directory) }
    }
}

/// Resumes a continuation at most once, from whichever racer gets there first.
private final class OnceResume: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Bool, Never>?
    init(_ continuation: CheckedContinuation<Bool, Never>) { self.continuation = continuation }
    func resume(_ value: Bool) {
        let c = lock.withLock { () -> CheckedContinuation<Bool, Never>? in
            defer { continuation = nil }
            return continuation
        }
        c?.resume(returning: value)
    }
}

#endif
