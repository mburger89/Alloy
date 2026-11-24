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
//   onReceive        {"<method>": [{method, params, id?}]} sent to Alloy each time a message with that method arrives
//   crashAfter n     exit(1) after n received messages
//   exitOnInitialize exit(1) on `initialize` without answering
//   garbageStdout    write "hello\n" before any frame
//   ignoreSigterm    ignore SIGTERM and stdin EOF (only SIGKILL ends the process)
//   spawnChild       start `sleep 600` in the same group; its pid goes to <log>.child
//   stopReadingAfterInit  after `initialized`, never read stdin again
//   flood {method, params, perSecond, seconds, counter?}  notifications to Alloy after `initialized`; with `counter` the
//                    params' `version` is the running count, so every message differs
//   logEnv [names]   <log>.env receives {name: value} for those variables
//   readFile "<path>"  reads the file at start; <log>.read gets `ok` or `denied`
//   writeFile "<path>" creates the file at start; <log>.write gets `ok` or `denied`
//   connect "<ip>:<port>"  TCP connect at start; <log>.connect gets `ok` or `denied`
//   connectUnix "<path>"  Unix-domain socket connect at start; <log>.unix gets `ok` or `denied`
//   resolve "<host>"  DNS lookup at start; <log>.resolve gets `ok` or `denied`
//   stderr "text"    written to stderr after `initialized`
//   stderrEnv [names] those variables' values written to stderr
// Every received message is appended to --log as one JSON line. The process exits when stdin closes.

/// Writes a small sidecar file atomically, or with plain POSIX calls where the atomic rename is refused (in the sandbox).
func put(_ text: String, to path: String) {
    if (try? text.write(toFile: path, atomically: true, encoding: .utf8)) != nil { return }
    let fd = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
    guard fd >= 0 else { return }
    _ = text.withCString { write(fd, $0, strlen($0)) }
    close(fd)
}

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

    func send(_ item: JSONValue) {
        guard let method = item["method"]?.stringValue else { return }
        var message: [String: JSONValue] = ["jsonrpc": .string("2.0"), "method": .string(method)]
        if let params = item["params"] { message["params"] = params }
        if let id = item["id"] { message["id"] = id }
        out.send(.object(message))
    }

    mutating func afterInitialized() {
        if let name = script["stderr"]?.stringValue { FileHandle.standardError.write(Data(name.utf8)) }
        let env = ProcessInfo.processInfo.environment
        for name in script["stderrEnv"]?.arrayValue?.compactMap(\.stringValue) ?? [] {
            FileHandle.standardError.write(Data("\(name)=\(env[name] ?? "")\n".utf8))
        }
        for item in script["afterInitialized"]?.arrayValue ?? [] { send(item) }
        if let flood = script["flood"], let method = flood["method"]?.stringValue {
            let perSecond = max(1, flood["perSecond"]?.intValue ?? 1)
            let seconds = flood["seconds"]?.doubleValue ?? 1
            let params = flood["params"]
            let counter = flood["counter"]?.boolValue == true
            let out = self.out
            Thread.detachNewThread {
                let deadline = Date().addingTimeInterval(seconds)
                var count = 0
                while Date() < deadline {
                    var message: [String: JSONValue] = ["jsonrpc": .string("2.0"), "method": .string(method)]
                    if var p = params {
                        if counter, case .object(var o) = p { count += 1; o["version"] = .number(Double(count)); p = .object(o) }
                        message["params"] = p
                    }
                    out.send(.object(message))
                    Thread.sleep(forTimeInterval: 1.0 / Double(perSecond))
                }
            }
        }
        if script["stopReadingAfterInit"]?.boolValue == true { while true { Thread.sleep(forTimeInterval: 3600) } }
    }

    static func connects(_ target: String) -> Bool {
        let parts = target.split(separator: ":")
        guard parts.count == 2, let port = UInt16(parts[1]) else { return false }
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        inet_pton(AF_INET, String(parts[0]), &address.sin_addr)
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        return result == 0
    }

    static func connectsUnix(_ path: String) -> Bool {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8CString)
        guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else { return false }
        withUnsafeMutableBytes(of: &address.sun_path) { raw in for (i, b) in bytes.enumerated() { raw[i] = UInt8(bitPattern: b) } }
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        return result == 0
    }

    static func resolves(_ host: String) -> Bool {
        var hints = addrinfo()
        hints.ai_family = AF_INET
        hints.ai_socktype = SOCK_STREAM
        var result: UnsafeMutablePointer<addrinfo>?
        let status = getaddrinfo(host, "443", &hints, &result)
        if let result { freeaddrinfo(result) }
        return status == 0
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
                    put("\(pid)", to: logPath + ".child")
                } else {
                    put("denied", to: logPath + ".child")
                }
                posix_spawn_file_actions_destroy(&actions)
                for p in argv { free(p) }
            }
            if let path = script["readFile"]?.stringValue {
                let ok = FileManager.default.contents(atPath: path) != nil
                put((ok ? "ok" : "denied"), to: logPath + ".read")
            }
            if let path = script["writeFile"]?.stringValue {
                let fd = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
                if fd >= 0 { close(fd) }
                put((fd >= 0 ? "ok" : "denied"), to: logPath + ".write")
            }
            if let target = script["connect"]?.stringValue {
                put((Self.connects(target) ? "ok" : "denied"), to: logPath + ".connect")
            }
            if let target = script["connectUnix"]?.stringValue {
                put((Self.connectsUnix(target) ? "ok" : "denied"), to: logPath + ".unix")
            }
            if let host = script["resolve"]?.stringValue {
                put((Self.resolves(host) ? "ok" : "denied"), to: logPath + ".resolve")
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
                    for item in script["onReceive"]?[method]?.arrayValue ?? [] { send(item) }
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
