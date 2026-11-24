import AlloyCore
import AlloyRPC
import Foundation

// Scriptable fake plugin, used only by the plugin tests. Arguments: --script <file> --log <file>.
//
// The script (JSON object, all keys optional):
//   replies          {"<method>": [ {result?, error?: {code, message}, delayMs?, hold?} ]} for any request except initialize:
//                    consumed in order, the last repeats; no entry answers null. `hold: true` answers (-32800) only when
//                    Alloy sends $/cancelRequest.
//   initializeResult the result of `initialize` (default {apiVersion: 1})
//   afterInitialized [{method, params, id?}] sent to Alloy after `initialized` (a request when `id` is set); the answers are
//                    logged like any received message
//   crashAfter n     exit(1) after n received messages
//   exitOnInitialize exit(1) on `initialize` without answering
//   garbageStdout    write "hello\n" before any frame
//   ignoreSigterm    ignore SIGTERM and stdin EOF (only SIGKILL ends the process)
//   spawnChild       start `sleep 600` in the same group; its pid goes to <log>.child
//   stopReadingAfterInit  after `initialized`, never read stdin again
//   flood {method, params, perSecond, seconds}  notifications to Alloy after `initialized`
//   logEnv [names]   <log>.env receives {name: value} for those variables
//   stderr "text"    written to stderr after `initialized`
//   stderrEnv [names] those variables' values written to stderr
// Every received message is appended to --log as one JSON line. The process exits when stdin closes.

final class Output: @unchecked Sendable {
    private let lock = NSLock()
    private let logFD: Int32

    init(logPath: String?) {
        logFD = logPath.map { open($0, O_WRONLY | O_APPEND | O_CREAT, 0o644) } ?? -1
    }

    static func encode(_ v: JSONValue) -> Data {
        let e = JSONEncoder()
        e.outputFormatting = [.withoutEscapingSlashes, .sortedKeys]
        return (try? e.encode(v)) ?? Data()
    }

    func send(_ v: JSONValue) {
        lock.withLock { FileHandle.standardOutput.write(RPCFrame.encode(Self.encode(v))) }
    }

    func log(_ v: JSONValue) {
        guard logFD >= 0 else { return }
        var line = Self.encode(v)
        line.append(0x0A)
        lock.withLock { line.withUnsafeBytes { _ = write(logFD, $0.baseAddress, $0.count) } }
    }
}

struct FakePlugin {
    var script: JSONValue = .object([:])
    var logPath: String?
    let out: Output
    var received = 0
    var replyCounts: [String: Int] = [:]
    var held: [JSONValue] = []

    init(script: JSONValue, logPath: String?) {
        self.script = script
        self.logPath = logPath
        out = Output(logPath: logPath)
    }

    func reply(id: JSONValue, result: JSONValue) {
        out.send(.object(["jsonrpc": .string("2.0"), "id": id, "result": result]))
    }

    func replyError(id: JSONValue, code: Int, message: String) {
        out.send(.object(["jsonrpc": .string("2.0"), "id": id,
                          "error": .object(["code": .number(Double(code)), "message": .string(message)])]))
    }

    mutating func handleRequest(method: String, id: JSONValue) {
        if method == "initialize" {
            if script["exitOnInitialize"]?.boolValue == true { exit(1) }
            reply(id: id, result: script["initializeResult"] ?? .object(["apiVersion": .number(1)]))
            return
        }
        let entries = script["replies"]?[method]?.arrayValue ?? []
        guard !entries.isEmpty else { reply(id: id, result: .null); return }
        let index = min(replyCounts[method, default: 0], entries.count - 1)
        replyCounts[method, default: 0] += 1
        let entry = entries[index]
        if entry["hold"]?.boolValue == true { held.append(id); return }
        if let ms = entry["delayMs"]?.intValue, ms > 0 { Thread.sleep(forTimeInterval: Double(ms) / 1000) }
        if let error = entry["error"] {
            replyError(id: id, code: error["code"]?.intValue ?? -32603, message: error["message"]?.stringValue ?? "")
        } else {
            reply(id: id, result: entry["result"] ?? .null)
        }
    }

    mutating func afterInitialized() {
        if let name = script["stderr"]?.stringValue { FileHandle.standardError.write(Data(name.utf8)) }
        let env = ProcessInfo.processInfo.environment
        for name in script["stderrEnv"]?.arrayValue?.compactMap(\.stringValue) ?? [] {
            FileHandle.standardError.write(Data("\(name)=\(env[name] ?? "")\n".utf8))
        }
        for item in script["afterInitialized"]?.arrayValue ?? [] {
            guard let method = item["method"]?.stringValue else { continue }
            var message: [String: JSONValue] = ["jsonrpc": .string("2.0"), "method": .string(method)]
            if let params = item["params"] { message["params"] = params }
            if let id = item["id"] { message["id"] = id }
            out.send(.object(message))
        }
        if let flood = script["flood"], let method = flood["method"]?.stringValue {
            let perSecond = max(1, flood["perSecond"]?.intValue ?? 1)
            let seconds = flood["seconds"]?.doubleValue ?? 1
            let params = flood["params"]
            let out = self.out
            Thread.detachNewThread {
                let deadline = Date().addingTimeInterval(seconds)
                while Date() < deadline {
                    var message: [String: JSONValue] = ["jsonrpc": .string("2.0"), "method": .string(method)]
                    if let params { message["params"] = params }
                    out.send(.object(message))
                    Thread.sleep(forTimeInterval: 1.0 / Double(perSecond))
                }
            }
        }
        if script["stopReadingAfterInit"]?.boolValue == true { while true { Thread.sleep(forTimeInterval: 3600) } }
    }

    mutating func run() {
        let env = ProcessInfo.processInfo.environment
        if script["garbageStdout"]?.boolValue == true { FileHandle.standardOutput.write(Data("hello\n".utf8)) }
        let ignore = script["ignoreSigterm"]?.boolValue == true
        if ignore { signal(SIGTERM, SIG_IGN) }
        if let logPath {
            if script["spawnChild"]?.boolValue == true {
                // posix_spawn without a new group or session keeps the child in this process's group.
                var pid: pid_t = 0
                let argv: [UnsafeMutablePointer<CChar>?] = [strdup("sleep"), strdup("600"), nil]
                var actions: posix_spawn_file_actions_t? = nil
                posix_spawn_file_actions_init(&actions)
                for fd in [Int32(0), 1, 2] { posix_spawn_file_actions_addopen(&actions, fd, "/dev/null", O_RDWR, 0) }
                if posix_spawn(&pid, "/bin/sleep", &actions, nil, argv, environ) == 0 {
                    try? "\(pid)".write(toFile: logPath + ".child", atomically: true, encoding: .utf8)
                }
                posix_spawn_file_actions_destroy(&actions)
                for p in argv { free(p) }
            }
            if let names = script["logEnv"]?.arrayValue?.compactMap(\.stringValue) {
                var values: [String: JSONValue] = [:]
                for name in names { if let v = env[name] { values[name] = .string(v) } }
                try? Output.encode(.object(values)).write(to: URL(fileURLWithPath: logPath + ".env"))
            }
        }
        var decoder = RPCFrameDecoder()
        while true {
            let chunk = FileHandle.standardInput.availableData
            if chunk.isEmpty {
                if ignore { while true { Thread.sleep(forTimeInterval: 3600) } }
                exit(0)
            }
            guard let bodies = try? decoder.append(chunk) else { exit(2) }
            for body in bodies {
                guard let message = JSONValue.parse(body) else { continue }
                out.log(message)
                if let method = message["method"]?.stringValue {
                    if let id = message["id"] {
                        handleRequest(method: method, id: id)
                    } else if method == "$/cancelRequest" {
                        for id in held { replyError(id: id, code: -32800, message: "cancelled") }
                        held = []
                    } else if method == "initialized" {
                        afterInitialized()
                    }
                }
                received += 1
                if let limit = script["crashAfter"]?.intValue, received >= limit { exit(1) }
            }
        }
    }
}

var scriptPath: String?
var logPath: String?
var args = CommandLine.arguments.dropFirst().makeIterator()
while let arg = args.next() {
    if arg == "--script" { scriptPath = args.next() } else if arg == "--log" { logPath = args.next() }
}
let script = scriptPath.flatMap { try? Data(contentsOf: URL(fileURLWithPath: $0)) }.flatMap { JSONValue.parse($0) } ?? .object([:])
var fake = FakePlugin(script: script, logPath: logPath)
fake.run()
