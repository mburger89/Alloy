#if !os(Windows)

import AlloyTerminal
import Dispatch
import Foundation
import MetalUITerminal

/// A deterministic pty: tests feed output, finish it and inspect what the session did to it.
public final class ScriptedPty: PtyHandle, @unchecked Sendable {
    public let processID: Int32
    private let lock = NSLock()
    private var queued: [UInt8] = []
    private var queue: DispatchQueue?
    private var handler: (@Sendable () -> Void)?
    private var status: PseudoTerminal.ExitStatus?
    private var waiters: [CheckedContinuation<PseudoTerminal.ExitStatus, Never>] = []
    private var _written: [UInt8] = []
    private var _resizes: [TerminalSize] = []
    private var _signals: [PseudoTerminal.Signal] = []
    private var _foreground: Int32?
    private var _closed = false
    private var _ignoresHangup = false
    private var _readCalls: [Int] = []

    public init(processID: Int32 = 1000) {
        self.processID = processID
    }

    // MARK: Test controls

    /// Queues readable bytes and fires the handler on its queue.
    public func feed(_ bytes: [UInt8]) {
        lock.lock()
        queued.append(contentsOf: bytes)
        let target = (queue, handler)
        lock.unlock()
        if let q = target.0, let h = target.1 { q.async(execute: h) }
    }

    /// Ends the pty: `exitStatus` resolves, and reads return -1 once the queued bytes are drained.
    public func finish(_ status: PseudoTerminal.ExitStatus) {
        lock.lock()
        if self.status != nil { lock.unlock(); return }
        self.status = status
        let waiting = waiters
        waiters = []
        let target = (queue, handler)
        lock.unlock()
        for w in waiting { w.resume(returning: status) }
        if let q = target.0, let h = target.1 { q.async(execute: h) }
    }

    public var written: [UInt8] { lock.withLock { _written } }
    public var resizes: [TerminalSize] { lock.withLock { _resizes } }
    public var signals: [PseudoTerminal.Signal] { lock.withLock { _signals } }
    public var closed: Bool { lock.withLock { _closed } }
    public var readCalls: [Int] { lock.withLock { _readCalls } }

    /// The foreground process group; defaults to `processID` (the shell itself).
    public var foreground: Int32? {
        get { lock.withLock { _foreground ?? processID } }
        set { lock.withLock { _foreground = newValue } }
    }

    /// When true a hangup does not end the pty; a kill still does.
    public var ignoresHangup: Bool {
        get { lock.withLock { _ignoresHangup } }
        set { lock.withLock { _ignoresHangup = newValue } }
    }

    // MARK: PtyHandle

    public func onReadable(queue: DispatchQueue, _ handler: @escaping @Sendable () -> Void) {
        lock.lock()
        if _closed { lock.unlock(); return }
        self.queue = queue
        self.handler = handler
        let pending = !queued.isEmpty || status != nil
        lock.unlock()
        if pending { queue.async(execute: handler) }
    }

    public func read(into buffer: UnsafeMutableRawBufferPointer) -> Int {
        lock.lock()
        defer { lock.unlock() }
        _readCalls.append(buffer.count)
        if _closed { return -1 }
        if queued.isEmpty { return status != nil ? -1 : 0 }
        guard let base = buffer.baseAddress, !buffer.isEmpty else { return 0 }
        let n = min(buffer.count, queued.count)
        queued.withUnsafeBytes { if let source = $0.baseAddress { base.copyMemory(from: source, byteCount: n) } }
        queued.removeFirst(n)
        return n
    }

    public func write(_ bytes: [UInt8]) {
        lock.withLock { if !_closed { _written.append(contentsOf: bytes) } }
    }

    public func resize(cols: Int, rows: Int) {
        lock.withLock { if !_closed { _resizes.append(TerminalSize(cols: cols, rows: rows)) } }
    }

    public func signalGroup(_ signal: PseudoTerminal.Signal) {
        let ends: PseudoTerminal.ExitStatus? = lock.withLock {
            if status != nil { return nil }   // no signal after the end
            _signals.append(signal)
            switch signal {
            case .kill: return .signaled(9)
            case .hangup: return _ignoresHangup ? nil : .signaled(1)
            case .terminate: return .signaled(15)
            case .interrupt: return .signaled(2)
            }
        }
        if let ends { finish(ends) }
    }

    public func foregroundProcessGroup() -> Int32? {
        lock.withLock { _closed ? nil : (_foreground ?? processID) }
    }

    public var exitStatus: PseudoTerminal.ExitStatus {
        get async {
            await withCheckedContinuation { continuation in
                lock.lock()
                if let status {
                    lock.unlock()
                    continuation.resume(returning: status)
                } else {
                    waiters.append(continuation)
                    lock.unlock()
                }
            }
        }
    }

    public func close() {
        lock.withLock {
            _closed = true
            handler = nil
            queue = nil
        }
    }
}

/// Hands out `ScriptedPty`s and records the requests.
public final class ScriptedPtySpawner: PtySpawner, @unchecked Sendable {
    private let lock = NSLock()
    private var _requests: [PtySpawnRequest] = []
    private var _spawned: [ScriptedPty] = []
    private var _failure: PseudoTerminalError?
    private var _nextProcessID: Int32

    public init(nextProcessID: Int32 = 1000) {
        _nextProcessID = nextProcessID
    }

    public var requests: [PtySpawnRequest] { lock.withLock { _requests } }
    public var spawned: [ScriptedPty] { lock.withLock { _spawned } }
    public var failure: PseudoTerminalError? {
        get { lock.withLock { _failure } }
        set { lock.withLock { _failure = newValue } }
    }
    public var nextProcessID: Int32 {
        get { lock.withLock { _nextProcessID } }
        set { lock.withLock { _nextProcessID = newValue } }
    }

    public func spawn(_ request: PtySpawnRequest) throws(PseudoTerminalError) -> any PtyHandle {
        lock.lock()
        _requests.append(request)
        if let failure = _failure { lock.unlock(); throw failure }
        let pty = ScriptedPty(processID: _nextProcessID)
        _nextProcessID += 1
        _spawned.append(pty)
        lock.unlock()
        return pty
    }
}

#endif
