#if !os(Windows)

import Dispatch
import Foundation
import MetalUITerminal

/// Everything needed to start one shell on a pty.
public struct PtySpawnRequest: Sendable, Equatable {
    public var executable: String
    public var argv: [String]
    public var env: [String: String]
    public var cwd: String
    public var size: TerminalSize

    public init(executable: String, argv: [String], env: [String: String], cwd: String, size: TerminalSize) {
        self.executable = executable
        self.argv = argv
        self.env = env
        self.cwd = cwd
        self.size = size
    }
}

/// The part of a pty a session uses; `PseudoTerminal` conforms, tests substitute a scripted fake.
public protocol PtyHandle: AnyObject, Sendable {
    var processID: Int32 { get }
    /// Calls `handler` on `queue` when output is available or the pty ended.
    func onReadable(queue: DispatchQueue, _ handler: @escaping @Sendable () -> Void)
    /// Reads into `into`: bytes read, 0 when nothing is available now, -1 at end of file.
    func read(into: UnsafeMutableRawBufferPointer) -> Int
    func write(_ bytes: [UInt8])
    func resize(cols: Int, rows: Int)
    func signalGroup(_ signal: PseudoTerminal.Signal)
    func foregroundProcessGroup() -> Int32?
    var exitStatus: PseudoTerminal.ExitStatus { get async }
    func close()
}

extension PseudoTerminal: PtyHandle {}

/// Starts ptys; the live one wraps `PseudoTerminal.spawn`.
public protocol PtySpawner: Sendable {
    func spawn(_ request: PtySpawnRequest) throws(PseudoTerminalError) -> any PtyHandle
}

#endif
