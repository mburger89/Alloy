import AlloyCore
import Foundation
import AlloyTestSupport
@testable import AlloyACP

/// Events a transport produced, collected for assertions.
final class Events: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [ProcessEvent] = []
    var all: [ProcessEvent] { lock.withLock { items } }
    var messages: [InboundMessage] { all.compactMap { if case .message(let m) = $0 { m } else { nil } } }
    func add(_ e: ProcessEvent) { lock.withLock { items.append(e) } }
    var echoes: [String] { messages.compactMap { if case .userEcho(let t, _, _, _) = $0 { t } else { nil } } }
    var notices: [String] { messages.compactMap { if case .notice(_, let t) = $0 { t } else { nil } } }
    var text: String { messages.compactMap { if case .delta(.text(_, let s)) = $0 { s } else { nil } }.joined() }
    var results: Int { messages.filter { if case .result = $0 { true } else { false } }.count }
    var hasSystemInit: Bool { messages.contains { if case .systemInit = $0 { true } else { false } } }
    var controlRequests: [ControlRequest] { messages.compactMap { if case .controlRequest(let r) = $0 { r } else { nil } } }
    func otherRequests(_ subtype: String) -> [JSONValue] {
        controlRequests.compactMap { if case .other(let s, let b) = $0.kind, s == subtype { b } else { nil } }
    }
}

let hsInitPlain = #"{"send":{"jsonrpc":"2.0","id":"$id","result":{"protocolVersion":1,"agentCapabilities":{"promptCapabilities":{"image":true}},"authMethods":[]}}}"#
func hsInit(_ caps: String, auth: String = "[]") -> String {
    #"{"send":{"jsonrpc":"2.0","id":"$id","result":{"protocolVersion":1,"agentCapabilities":"# + caps + #","authMethods":"# + auth + "}}}"
}
let hsNew = #"{"send":{"jsonrpc":"2.0","id":"$id","result":{"sessionId":"new1","modes":{"currentModeId":"build","availableModes":[{"id":"build","name":"Build"}]}}}}"#
let hsOK = #"{"send":{"jsonrpc":"2.0","id":"$id","result":{}}}"#
let turnDone = #"{"send":{"jsonrpc":"2.0","id":"$id","result":{"stopReason":"end_turn"}}}"#
func upd(_ body: String) -> String {
    #"{"send":{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"s1","update":"# + body + "}}}"
}

struct Rig {
    let scratch: Scratch
    let log: String
    let transport: ACPTransport
    let events: Events

    /// Starts a transport on the fake agent with `steps`.
    static func start(_ steps: [String], configure: (inout ACPLaunchConfiguration) -> Void = { _ in },
                      clock: any AutosaveClock = SystemAutosaveClock()) async throws -> Rig {
        let s = Scratch()
        let log = s.url.appendingPathComponent("log.txt").path
        let env = ["FAKE_ACP_SCRIPT": s.script(steps), "FAKE_ACP_LOG": log]
        let def = AgentDefinition(id: "fake", name: "Fake", command: fakeAgentPath)
        var config = ACPLaunchConfiguration(agent: def, executable: URL(fileURLWithPath: fakeAgentPath), arguments: [],
                                            projectDirectory: s.url, sessionID: UUID(), env: env)
        configure(&config)
        let t = ACPTransport(configuration: config, clock: clock)
        let stream = try await t.start()
        let events = Events()
        Task { for await e in stream { events.add(e) } }
        return Rig(scratch: s, log: log, transport: t, events: events)
    }

    var logText: String { (try? String(contentsOfFile: log, encoding: .utf8)) ?? "" }
    /// The received lines for one method, in order.
    func lines(_ method: String) -> [String] {
        logText.split(separator: "\n").map(String.init).filter { $0.contains("\"method\":\"\(method.replacingOccurrences(of: "/", with: "\\/"))\"") }
    }
    func stop() async { await transport.stopAndWait(timeout: .seconds(3)) }
}

func user(_ text: String, id: UUID = UUID(), priority: Priority? = nil) -> OutboundMessage {
    .user(content: [.text(text)], uuid: id, priority: priority)
}
