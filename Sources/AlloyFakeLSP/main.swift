import AlloyCore
import AlloyLSP
import Foundation

// Scriptable fake language server, used only by the AlloyLSP tests.
//
// FAKE_LSP_SCRIPT (JSON object, all keys optional):
//   capabilities   object returned as InitializeResult.capabilities
//   diagnostics    array published after didOpen/didChange (echoing the document version)
//   definition     result for textDocument/definition
//   semanticTokens result for textDocument/semanticTokens/full (and /full/delta unless semanticTokensDelta is set)
//   semanticTokensDelta  result for textDocument/semanticTokens/full/delta (e.g. {resultId, edits})
//   semanticTokensFirst  result for the first semanticTokens request only (later ones use semanticTokens)
//   refreshSemanticAfterFirst  true: after answering the first semanticTokens request, send workspace/semanticTokens/refresh
//   semanticTokensDeltaError  true: a /full/delta request is answered with a JSON-RPC error
//   semanticDelayMs  sleep before answering a semanticTokens request only
//   holdSemanticTokens  true: a semanticTokens request is answered only once the client cancels it (with null)
//   serverRequests array of {id, method, params} sent to the client after `initialized`
//   crashAfter     exit(1) after this many received messages (the reply to the last one is sent first)
//   crashLaunches  crashAfter applies only to the first N launches of this log (default: all)
//   exitOnInitializeFromLaunch  from launch k on, exit(1) on `initialize` without replying
//   stallAfterInitialized  after `initialized`, stop reading stdin forever (fills the pipe)
//   holdDefinition  true: a definition request is answered only once the client cancels it (with null); never otherwise
//   delayMs        sleep before each response
//   shutdownDelayMs  sleep before answering `shutdown`
// FAKE_LSP_LOG: file that receives every received message as one JSON line.
// FAKE_LSP_LOG + ".docs": one JSON line {uri, version, text} per didOpen/didChange with the document text the
//   server reconstructed (incremental changes are applied in the negotiated position encoding).
// FAKE_LSP_LOG + ".errors": one JSON line {error} per protocol violation (out-of-range position, change, save
//   or close for a document that is not open, duplicate didOpen); tracking stops after the first.

/// The fake's view of the open documents, as UTF-8 bytes. Strict: a position outside the document, or a
/// change/save/close for a document that was not opened, is recorded as an error and stops further tracking.
final class FakeDocuments {
    var texts: [String: [UInt8]] = [:]
    var errors: [String] = []

    /// Byte offset of `line`/`character` (UTF-16 units, or bytes when `utf8`); nil when outside the document.
    /// A line's content ends before its `\n` and before a `\r` directly in front of it.
    static func offset(_ bytes: [UInt8], line: Int, character: Int, utf8: Bool) -> Int? {
        guard line >= 0, character >= 0 else { return nil }
        var start = 0
        var row = 0
        while row < line {
            guard let nl = bytes[start...].firstIndex(of: 0x0A) else { return nil }
            start = nl + 1
            row += 1
        }
        var end = start
        while end < bytes.count, bytes[end] != 0x0A { end += 1 }
        if end > start, end < bytes.count, bytes[end - 1] == 0x0D { end -= 1 }
        if utf8 { return start + character <= end ? start + character : nil }
        var units = 0
        var i = start
        while i < end, units < character {
            let b = bytes[i]
            let len = b >= 0xF0 ? 4 : b >= 0xE0 ? 3 : b >= 0xC0 ? 2 : 1
            units += len == 4 ? 2 : 1
            i += len
        }
        return units == character && i <= end ? i : nil
    }

    func change(uri: String, edits: [JSONValue], utf8: Bool) {
        guard errors.isEmpty else { return }
        guard var bytes = texts[uri] else { errors.append("didChange for unopened \(uri)"); return }
        for edit in edits {
            let newText = Array((edit["text"]?.stringValue ?? "").utf8)
            if let range = edit["range"], let sl = range["start"]?["line"]?.intValue, let sc = range["start"]?["character"]?.intValue,
               let el = range["end"]?["line"]?.intValue, let ec = range["end"]?["character"]?.intValue {
                guard let lo = Self.offset(bytes, line: sl, character: sc, utf8: utf8),
                      let hi = Self.offset(bytes, line: el, character: ec, utf8: utf8), hi >= lo else {
                    errors.append("range out of bounds \(sl):\(sc)-\(el):\(ec) in \(uri)")
                    return
                }
                bytes.replaceSubrange(lo..<hi, with: newText)
            } else {
                bytes = newText
            }
        }
        texts[uri] = bytes
    }
}

struct FakeLSP {
    let documents = FakeDocuments()
    var docsFD: Int32 = -1
    var errorsFD: Int32 = -1
    var script: JSONValue = .object([:])
    var logFD: Int32 = -1
    var received = 0
    var semanticRequests = 0
    var launchIndex = 1

    init() {
        let env = ProcessInfo.processInfo.environment
        if let s = env["FAKE_LSP_SCRIPT"], let v = JSONValue.parse(Data(s.utf8)) { script = v }
        if let path = env["FAKE_LSP_LOG"] {
            logFD = open(path, O_WRONLY | O_APPEND | O_CREAT, 0o644)
            docsFD = open(path + ".docs", O_WRONLY | O_APPEND | O_CREAT, 0o644)
            errorsFD = open(path + ".errors", O_WRONLY | O_APPEND | O_CREAT, 0o644)
            // One byte per launch in a side file gives this process its launch number.
            let counter = open(path + ".launches", O_WRONLY | O_APPEND | O_CREAT, 0o644)
            _ = write(counter, "x", 1)
            close(counter)
            launchIndex = ((try? FileManager.default.attributesOfItem(atPath: path + ".launches")[.size] as? Int) ?? nil) ?? 1
        }
    }

    func encode(_ v: JSONValue) -> Data {
        let e = JSONEncoder()
        e.outputFormatting = [.withoutEscapingSlashes, .sortedKeys]
        return (try? e.encode(v)) ?? Data()
    }

    func log(_ v: JSONValue) {
        guard logFD >= 0 else { return }
        var line = encode(v)
        line.append(0x0A)
        line.withUnsafeBytes { _ = write(logFD, $0.baseAddress, $0.count) }
    }

    func trackDocument(method: String, params: JSONValue?) {
        guard let doc = params?["textDocument"], let uri = doc["uri"]?.stringValue else { return }
        let errorCount = documents.errors.count
        defer {
            if documents.errors.count > errorCount, let error = documents.errors.last, errorsFD >= 0 {
                var line = encode(.object(["error": .string(error)]))
                line.append(0x0A)
                line.withUnsafeBytes { _ = write(errorsFD, $0.baseAddress, $0.count) }
            }
        }
        switch method {
        case "textDocument/didOpen":
            if documents.texts[uri] != nil { documents.errors.append("duplicate didOpen for \(uri)") }
            documents.texts[uri] = Array((doc["text"]?.stringValue ?? "").utf8)
        case "textDocument/didChange":
            let utf8 = script["capabilities"]?["positionEncoding"]?.stringValue == "utf-8"
            documents.change(uri: uri, edits: params?["contentChanges"]?.arrayValue ?? [], utf8: utf8)
        default:   // didSave, didClose
            if documents.texts[uri] == nil { documents.errors.append("\(method) for unopened \(uri)") }
            if method == "textDocument/didClose" { documents.texts[uri] = nil }
            return
        }
        guard docsFD >= 0 else { return }
        var line = encode(.object(["uri": .string(uri), "version": doc["version"] ?? .null,
                                   "text": .string(String(decoding: documents.texts[uri] ?? [], as: UTF8.self))]))
        line.append(0x0A)
        line.withUnsafeBytes { _ = write(docsFD, $0.baseAddress, $0.count) }
    }

    func send(_ v: JSONValue) {
        FileHandle.standardOutput.write(LSPFrame.encode(encode(v)))
    }

    func respond(id: JSONValue, result: JSONValue) {
        if let ms = script["delayMs"]?.intValue, ms > 0 { Thread.sleep(forTimeInterval: Double(ms) / 1000) }
        send(.object(["jsonrpc": .string("2.0"), "id": id, "result": result]))
    }

    func respondError(id: JSONValue, message: String) {
        send(.object(["jsonrpc": .string("2.0"), "id": id,
                      "error": .object(["code": .number(-32801), "message": .string(message)])]))
    }

    mutating func run() {
        var decoder = LSPFrameDecoder()
        while true {
            let chunk = FileHandle.standardInput.availableData
            if chunk.isEmpty { exit(0) }
            guard let bodies = try? decoder.append(chunk) else { exit(2) }
            for body in bodies {
                guard let message = JSONValue.parse(body) else { continue }
                log(message)
                handle(message)
                received += 1
                if let limit = script["crashAfter"]?.intValue, received >= limit,
                   launchIndex <= (script["crashLaunches"]?.intValue ?? Int.max) {
                    FileHandle.standardError.write(Data("fake-lsp: crashing after \(received) messages\n".utf8))
                    exit(1)
                }
            }
        }
    }

    mutating func handle(_ message: JSONValue) {
        guard let method = message["method"]?.stringValue else { return }  // a response from the client
        let id = message["id"]
        let params = message["params"]
        switch method {
        case "initialize":
            guard let id else { return }
            if let from = script["exitOnInitializeFromLaunch"]?.intValue, launchIndex >= from {
                FileHandle.standardError.write(Data("fake-lsp: dying during initialize\n".utf8))
                exit(1)
            }
            respond(id: id, result: .object([
                "capabilities": script["capabilities"] ?? .object([:]),
                "serverInfo": .object(["name": .string("alloy-fake-lsp")]),
            ]))
        case "initialized":
            if script["stallAfterInitialized"]?.boolValue == true { while true { Thread.sleep(forTimeInterval: 3600) } }
            for request in script["serverRequests"]?.arrayValue ?? [] {
                var out: [String: JSONValue] = ["jsonrpc": .string("2.0")]
                out["id"] = request["id"]
                out["method"] = request["method"]
                out["params"] = request["params"]
                send(.object(out))
            }
        case "shutdown":
            if let ms = script["shutdownDelayMs"]?.intValue, ms > 0 { Thread.sleep(forTimeInterval: Double(ms) / 1000) }
            if let id { respond(id: id, result: .null) }
        case "exit":
            exit(0)
        case "textDocument/didOpen", "textDocument/didChange", "textDocument/didSave", "textDocument/didClose":
            trackDocument(method: method, params: params)
            guard method != "textDocument/didSave", method != "textDocument/didClose",
                  let diagnostics = script["diagnostics"], let doc = params?["textDocument"],
                  let uri = doc["uri"] else { return }
            var p: [String: JSONValue] = ["uri": uri, "diagnostics": diagnostics]
            if let version = doc["version"] { p["version"] = version }
            send(.object(["jsonrpc": .string("2.0"), "method": .string("textDocument/publishDiagnostics"),
                          "params": .object(p)]))
        case "textDocument/diagnostic":
            if let id { respond(id: id, result: .object(["kind": .string("full"), "items": script["pullDiagnostics"] ?? .array([])])) }
        case "textDocument/definition":
            if script["holdDefinition"]?.boolValue == true { return }
            if let id { respond(id: id, result: script["definition"] ?? .null) }
        case "$/cancelRequest":
            // A held request is released by its cancellation.
            if script["holdSemanticTokens"]?.boolValue == true, let held = params?["id"] { respond(id: held, result: .null) }
            if script["holdDefinition"]?.boolValue == true, let held = params?["id"] { respond(id: held, result: .null) }
        case "textDocument/semanticTokens/full", "textDocument/semanticTokens/full/delta":
            if script["holdSemanticTokens"]?.boolValue == true { return }
            if let ms = script["semanticDelayMs"]?.intValue, ms > 0 { Thread.sleep(forTimeInterval: Double(ms) / 1000) }
            semanticRequests += 1
            if method.hasSuffix("/delta"), script["semanticTokensDeltaError"]?.boolValue == true {
                if let id { respondError(id: id, message: "content modified") }
                return
            }
            var result = method.hasSuffix("/delta") ? (script["semanticTokensDelta"] ?? script["semanticTokens"]) : script["semanticTokens"]
            if semanticRequests == 1, let first = script["semanticTokensFirst"] { result = first }
            if let id { respond(id: id, result: result ?? .null) }
            if semanticRequests == 1, script["refreshSemanticAfterFirst"]?.boolValue == true {
                send(.object(["jsonrpc": .string("2.0"), "id": .number(9001), "method": .string("workspace/semanticTokens/refresh")]))
            }
        default:
            if let id { respond(id: id, result: .null) }
        }
    }
}

var server = FakeLSP()
server.run()
