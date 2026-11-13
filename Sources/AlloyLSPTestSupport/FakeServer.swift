import AlloyLSP
import Foundation

/// The scriptable fake language server (`AlloyFakeLSP`), which the test targets depend on so that SwiftPM always builds
/// it next to the test bundle. A missing binary is a build error, never a skipped suite.
public let fakeServerPath: String = {
    // Next to the test bundle (where the build system puts every product), else under the repository's `.build/debug`.
    let beside = Bundle.allBundles.first { $0.bundleURL.pathExtension == "xctest" }
        .map { $0.bundleURL.deletingLastPathComponent().appendingPathComponent("AlloyFakeLSP").path }
    if let beside, FileManager.default.isExecutableFile(atPath: beside) { return beside }
    let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    return root.appendingPathComponent(".build/debug/AlloyFakeLSP").path
}()

/// Polls `condition` every 20 ms until it holds or `timeout` passes; returns its last answer. The condition runs on the
/// caller's actor, so a main-actor test can read main-actor state in it.
public func waitUntil(_ timeout: Duration = .seconds(10), isolation: isolated (any Actor)? = #isolation,
                      _ condition: () async -> Bool) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while clock.now < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(20))
    }
    return await condition()
}

/// The server processes a test's launcher started, by server id.
public final class Launches: @unchecked Sendable {
    private let lock = NSLock()
    private var started: [(id: String, process: ServerProcess)] = []
    public init() {}
    /// How many launches happened while an earlier process of the same server id still ran.
    public var overlaps: Int { lock.withLock { overlapCount } }
    private var overlapCount = 0
    public func add(_ id: String, _ p: ServerProcess) {
        lock.lock()
        if started.contains(where: { $0.id == id && $0.process.isRunning }) { overlapCount += 1 }
        started.append((id, p))
        lock.unlock()
    }
    public func count(_ id: String? = nil) -> Int {
        lock.lock(); defer { lock.unlock() }
        return id.map { id in started.filter { $0.id == id }.count } ?? started.count
    }
    public func processes(_ id: String) -> [ServerProcess] {
        lock.lock(); defer { lock.unlock() }
        return started.filter { $0.id == id }.map(\.process)
    }
    public var all: [ServerProcess] { lock.lock(); defer { lock.unlock() }; return started.map(\.process) }
}

/// Collects a manager's results.
public final class Collector: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [LSPResult] = []
    private var task: Task<Void, Never>?
    public init(_ stream: AsyncStream<LSPResult>) {
        task = Task { [self] in for await r in stream { lock.withLock { items.append(r) } } }
    }
    public var all: [LSPResult] { lock.lock(); defer { lock.unlock() }; return items }
    /// The states reported for the server named `name` (all servers when nil).
    public func states(_ name: String? = nil) -> [ServerState] {
        all.compactMap { if case .status(_, _, let n, let s) = $0, name == nil || n == name { s } else { nil } }
    }
    deinit { task?.cancel() }
}
