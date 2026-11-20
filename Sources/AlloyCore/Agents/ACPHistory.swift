import Foundation

/// Alloy's own history file of one ACP session: the translated wire lines, appended as they arrive, one JSON object
/// per line in the shape of the CLI's transcript (so `InboundDecoder` reads them), plus `alloy_notice` lines.
/// A restored ACP session shows it without starting the agent. Lives in AlloyCore because the transport (AlloyACP)
/// writes it and the workspace reads it, and AlloyCore cannot import AlloyACP.
public final class ACPHistory: @unchecked Sendable {
    public let url: URL
    private let lock = NSLock()
    private var handle: FileHandle?

    public init(directory: URL, sessionID: UUID) {
        url = directory.appendingPathComponent("\(sessionID.uuidString.lowercased()).jsonl")
    }

    public static func url(directory: URL, sessionID: UUID) -> URL {
        ACPHistory(directory: directory, sessionID: sessionID).url
    }

    deinit { try? handle?.close() }

    /// Appends one line (a newline is added). Failures are silent: history is a convenience, never a reason to fail a turn.
    public func append(_ line: Data) {
        lock.withLock {
            if handle == nil {
                try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                if !FileManager.default.fileExists(atPath: url.path) {
                    FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600])
                }
                handle = try? FileHandle(forWritingTo: url)
                _ = try? handle?.seekToEnd()
            }
            guard let handle else { return }
            var out = line
            out.append(0x0A)
            try? handle.write(contentsOf: out)
        }
    }

    /// Every complete or cut-off line of the file; an empty list when the file is missing.
    public func read() -> [Data] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        return data.split(separator: 0x0A, omittingEmptySubsequences: true).map { Data($0) }
    }

    // MARK: encoding

    /// The history line for a message, or nil for messages history does not keep (deltas, controls, state).
    public static func encode(_ message: InboundMessage) -> Data? {
        let value: JSONValue
        switch message {
        case .userEcho(let text, let images, let uuid, let isReplay):
            guard !isReplay, !text.isEmpty || images > 0 else { return nil }
            var content: [JSONValue] = [.object(["type": .string("text"), "text": .string(text)])]
            for _ in 0..<images { content.append(.object(["type": .string("image")])) }
            var o: [String: JSONValue] = ["type": .string("user"),
                                          "message": .object(["role": .string("user"), "content": .array(content)])]
            if let uuid { o["uuid"] = .string(uuid) }
            value = .object(o)
        case .assistantBlock(let id, let block):
            let item: JSONValue
            switch block {
            case .text(let t): item = .object(["type": .string("text"), "text": .string(t)])
            case .thinking(let t): item = .object(["type": .string("thinking"), "thinking": .string(t)])
            case .toolUse(let tid, let name, let input, _):
                item = .object(["type": .string("tool_use"), "id": .string(tid), "name": .string(name), "input": input])
            }
            value = .object(["type": .string("assistant"),
                             "message": .object(["id": .string(id), "role": .string("assistant"), "content": .array([item])])])
        case .toolResult(let r):
            var block: [String: JSONValue] = ["type": .string("tool_result"), "tool_use_id": .string(r.toolUseID),
                                              "content": .string(r.text)]
            if r.isError { block["is_error"] = .bool(true) }
            var o: [String: JSONValue] = ["type": .string("user"),
                                          "message": .object(["role": .string("user"), "content": .array([.object(block)])])]
            if let raw = r.raw { o["tool_use_result"] = raw }
            value = .object(o)
        case .compactBoundary(let pre, let post):
            var meta: [String: JSONValue] = [:]
            if let pre { meta["pre_tokens"] = .number(Double(pre)) }
            if let post { meta["post_tokens"] = .number(Double(post)) }
            value = .object(["type": .string("system"), "subtype": .string("compact_boundary"), "compact_metadata": .object(meta)])
        case .notice(let kind, let text):
            value = .object(["type": .string("system"), "subtype": .string("alloy_notice"),
                             "kind": .string(kind.rawValue), "text": .string(text)])
        default:
            return nil
        }
        return try? JSONEncoder().encode(value)
    }

    /// Streams the file's messages as the live stream would have given them. Returns the number of lines that are not
    /// JSON objects (a last line cut off mid-write counts).
    public static func forEachMessage(in data: Data, _ emit: (InboundMessage) -> Void) -> Int {
        var skipped = 0
        for line in data.split(separator: 0x0A, omittingEmptySubsequences: true) {
            guard let root = JSONValue.parse(line), case .object = root, let type = root["type"]?.stringValue else {
                skipped += 1
                continue
            }
            if type == "system", root["subtype"]?.stringValue == "alloy_notice" {
                let kind = root["kind"]?.stringValue.flatMap(NoticeKind.init(rawValue:)) ?? .commandOutput
                emit(.notice(kind: kind, text: root["text"]?.stringValue ?? ""))
                continue
            }
            switch InboundDecoder.decode(root) {
            case .userEcho(let text, let images, let uuid, _):
                if text.isEmpty && images == 0 { continue }
                emit(.userEcho(text: text, imageCount: images, uuid: uuid, isReplay: false))
            case let m: if m.isHistoryKept { emit(m) }
            }
        }
        return skipped
    }
}

private extension InboundMessage {
    var isHistoryKept: Bool {
        switch self {
        case .assistantBlock, .toolResult, .compactBoundary: true
        default: false
        }
    }
}
