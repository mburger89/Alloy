import AlloyACP
import AlloyCore
import Foundation

/// The scriptable fake agent (`AlloyFakeACP`), which the test target depends on so SwiftPM always builds it.
let fakeAgentPath: String = {
    let beside = Bundle.allBundles.first { $0.bundleURL.pathExtension == "xctest" }
        .map { $0.bundleURL.deletingLastPathComponent().appendingPathComponent("AlloyFakeACP").path }
    if let beside, FileManager.default.isExecutableFile(atPath: beside) { return beside }
    let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    return root.appendingPathComponent(".build/debug/AlloyFakeACP").path
}()

func waitUntil(_ timeout: Duration = .seconds(10), _ condition: () -> Bool) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while clock.now < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(20))
    }
    return condition()
}

/// A temporary directory removed at the end of the test.
final class Scratch {
    let url: URL
    init() {
        url = FileManager.default.temporaryDirectory.appendingPathComponent("acp-test-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }
    deinit { try? FileManager.default.removeItem(at: url) }

    /// Writes a fake-agent script (one JSON step per line) and returns its path.
    func script(_ steps: [String]) -> String {
        let path = url.appendingPathComponent("script-\(UUID().uuidString).jsonl")
        try? steps.joined(separator: "\n").write(to: path, atomically: true, encoding: .utf8)
        return path.path
    }
    func launch(_ steps: [String], extraEnv: [String: String] = [:]) throws -> ACPProcess {
        var env = extraEnv
        env["FAKE_ACP_SCRIPT"] = script(steps)
        return try ACPProcess(command: fakeAgentPath, arguments: [], environment: env, currentDirectory: url)
    }
}

final class Box<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: T
    init(_ v: T) { value = v }
    func get() -> T { lock.withLock { value } }
    func set(_ v: T) { lock.withLock { value = v } }
    func update(_ f: (inout T) -> Void) { lock.withLock { f(&value) } }
}

/// Wires an `ACPConnection` straight to an in-memory pair of channels (no process).
struct Loopback {
    let connection: ACPConnection
    let feed: AsyncStream<Data>.Continuation
    let sent: Box<[Data]>
    let strays: Box<[String]>

    init() {
        let (stream, cont) = AsyncStream<Data>.makeStream()
        let sent = Box<[Data]>([]), strays = Box<[String]>([])
        self.sent = sent; self.strays = strays; self.feed = cont
        connection = ACPConnection(input: stream, output: { data in sent.update { $0.append(data) } },
                                   onStray: { line in strays.update { $0.append(line) } })
    }

    func send(_ line: String) { feed.yield(Data((line + "\n").utf8)) }

    /// The messages the connection wrote, decoded.
    var sentObjects: [JSONValue] {
        sent.get().flatMap { $0.split(separator: 0x0A) }.compactMap { JSONValue.parse($0) }
    }
}
