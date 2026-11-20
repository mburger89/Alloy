import Foundation

// Scriptable fake ACP agent, used only by the AlloyACP tests. It speaks newline-delimited JSON-RPC on stdio.
//
// FAKE_ACP_SCRIPT: path of a file with one JSON step per line (blank lines and lines starting with # are skipped):
//   {"expect": "method"}          read client messages until one has this method; remember its id for "$id"
//   {"expectResponse": <id>}      read client messages until a response with this id arrives
//   {"send": {...}}               write this object as a line; every string value "$id" is replaced by the id
//                                 of the last expected request
//   {"sleep": ms}                 sleep
//   {"stray": "text"}             write a non-JSON line
//   {"bigline": bytes}            write one notification line of about this many bytes (a long padding string)
//   {"stderr": "text"}            write to stderr
//   {"ignoreSignals": true}       ignore SIGINT and SIGTERM from now on
//   {"hang": true}                sleep forever
//   {"closeStdout": true}         close stdout (the agent keeps running)
//   {"exit": code}                exit
// After the last step the agent exits 0.
// FAKE_ACP_LOG: file that receives every received line.

setvbuf(stdout, nil, _IOFBF, 1 << 16)
let env = ProcessInfo.processInfo.environment
guard let scriptPath = env["FAKE_ACP_SCRIPT"], let scriptText = try? String(contentsOfFile: scriptPath, encoding: .utf8) else {
    FileHandle.standardError.write(Data("FAKE_ACP_SCRIPT missing\n".utf8))
    exit(2)
}
let logHandle: FileHandle? = env["FAKE_ACP_LOG"].flatMap { path in
    FileManager.default.createFile(atPath: path, contents: nil)
    return FileHandle(forWritingAtPath: path)
}

func write(_ line: String) {
    fputs(line + "\n", stdout)
    fflush(stdout)
}

func substitute(_ value: Any, id: Any?) -> Any {
    if let s = value as? String, s == "$id", let id { return id }
    if let a = value as? [Any] { return a.map { substitute($0, id: id) } }
    if let o = value as? [String: Any] { return o.mapValues { substitute($0, id: id) } }
    return value
}

func nextMessage() -> [String: Any]? {
    while let line = readLine(strippingNewline: true) {
        logHandle?.write(Data((line + "\n").utf8))
        if let d = line.data(using: .utf8), let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any] { return obj }
    }
    return nil
}

var lastID: Any?
for raw in scriptText.split(separator: "\n") {
    let line = raw.trimmingCharacters(in: .whitespaces)
    if line.isEmpty || line.hasPrefix("#") { continue }
    guard let step = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else { continue }
    if let method = step["expect"] as? String {
        var found = false
        while let msg = nextMessage() {
            if msg["method"] as? String == method { if let id = msg["id"] { lastID = id }; found = true; break }
        }
        if !found { exit(3) }
    } else if let id = step["expectResponse"] {
        var found = false
        while let msg = nextMessage() {
            if msg["method"] == nil, let got = msg["id"], "\(got)" == "\(id)" { found = true; break }
        }
        if !found { exit(3) }
    } else if let payload = step["send"] {
        let obj = substitute(payload, id: lastID)
        if let d = try? JSONSerialization.data(withJSONObject: obj, options: [.withoutEscapingSlashes]) {
            write(String(decoding: d, as: UTF8.self))
        }
    } else if let ms = step["sleep"] as? Double {
        usleep(UInt32(ms * 1000))
    } else if let text = step["stray"] as? String {
        write(text)
    } else if let n = step["bigline"] as? Int {
        write(#"{"jsonrpc":"2.0","method":"session/update","params":{"pad":""# + String(repeating: "x", count: n) + #""}}"#)
    } else if let text = step["stderr"] as? String {
        FileHandle.standardError.write(Data((text + "\n").utf8))
    } else if step["ignoreSignals"] != nil {
        signal(SIGINT, SIG_IGN)
        signal(SIGTERM, SIG_IGN)
    } else if step["hang"] != nil {
        while true { sleep(3600) }
    } else if step["closeStdout"] != nil {
        fflush(stdout)
        close(1)
    } else if let code = step["exit"] as? Int {
        fflush(stdout)
        exit(Int32(code))
    }
}
fflush(stdout)
exit(0)
