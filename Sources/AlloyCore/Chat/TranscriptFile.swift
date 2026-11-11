import Foundation

/// The CLI's own transcript of a conversation, `~/.claude/projects/<slug>/<session id>.jsonl`, read (never written)
/// to show earlier history when a restored session is opened.
public enum TranscriptFile {
    /// `<home>/.claude/projects/<slug>/<cliSessionID>.jsonl`. The slug is the real path of the project with every
    /// character outside `[A-Za-z0-9]` replaced by `-`, per UTF-16 unit like the CLI. Symlinks resolve first
    /// (the CLI uses the real path, so `/tmp` is `/private/tmp`).
    public static func url(cliSessionID: String, projectRoot: URL, home: URL) -> URL {
        // realpath, not resolvingSymlinksInPath: Foundation strips /private (/private/tmp/x -> /tmp/x), the CLI does not.
        let real = NotePath.realPath(projectRoot.path) ?? projectRoot.resolvingSymlinksInPath().path
        let slug = String(decoding: real.utf16.map { u -> UInt16 in
            switch u {
            case 0x30...0x39, 0x41...0x5A, 0x61...0x7A: return u
            default: return 0x2D
            }
        }, as: UTF16.self)
        return home.appendingPathComponent(".claude").appendingPathComponent("projects")
            .appendingPathComponent(slug).appendingPathComponent("\(cliSessionID).jsonl")
    }

    /// Maps transcript records to the messages the live stream would have given. See `forEachMessage`.
    public static func messages(from data: Data) -> (messages: [InboundMessage], skippedLines: Int) {
        var out: [InboundMessage] = []
        let skipped = forEachMessage(in: data) { out.append($0) }
        return (out, skipped)
    }

    /// Streams the transcript's records as the messages the live stream would have given, without holding them all.
    /// Only user prompts, tool results, assistant blocks, compact boundaries and synthetic command output are
    /// delivered (sidechain and meta records, attachments, queue operations, `api-request*`, `cost-state` and the
    /// rest are dropped without being parsed). Returns the number of lines that are not JSON objects (for example
    /// a last line cut off mid-write).
    public static func forEachMessage(in data: Data, _ emit: (InboundMessage) -> Void) -> Int {
        forEachMessage(in: data) { message, _ in emit(message) }
    }

    /// As above, with each record's own `timestamp` (nil when it has none or it does not parse).
    public static func forEachMessage(in data: Data, _ emit: (InboundMessage, Date?) -> Void) -> Int {
        let stamps = ISO8601DateFormatter()
        stamps.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plainStamps = ISO8601DateFormatter()
        var skipped = 0
        let wanted = ["\"type\":\"user\"", "\"type\":\"assistant\"", "\"type\":\"system\""].map { Data($0.utf8) }
        let newline = UInt8(ascii: "\n")
        var start = data.startIndex
        while start < data.endIndex {
            let end = data[start...].firstIndex(of: newline) ?? data.endIndex
            let line = data[start..<end]
            let isLast = end == data.endIndex
            start = end < data.endIndex ? data.index(after: end) : end
            if line.isEmpty { continue }
            // Cheap filter: escaped quotes inside strings never match `"type":"user"`, so a line that has none of
            // the three kept types cannot be a kept record. The last line is always parsed, to catch a cut-off write.
            if !isLast && !wanted.contains(where: { line.range(of: $0) != nil }) { continue }
            guard let root = JSONValue.parse(line), case .object(var fields) = root,
                  let type = fields["type"]?.stringValue else { skipped += 1; continue }
            if fields["isSidechain"]?.boolValue == true { continue }
            let date = fields["timestamp"]?.stringValue.flatMap { stamps.date(from: $0) ?? plainStamps.date(from: $0) }
            switch type {
            case "user":
                if fields["isMeta"]?.boolValue == true { continue }
                if let result = fields.removeValue(forKey: "toolUseResult") {
                    // The transcript spells the key in camelCase; the live stream uses snake_case.
                    fields["tool_use_result"] = result
                }
                let decoded = InboundDecoder.decode(.object(fields))
                switch decoded {
                case .userEcho(let text, let images, let uuid, _):
                    if text.isEmpty && images == 0 { continue }
                    // Not a replay echo: a replayed history is applied to its own transcript, where no
                    // pending message can match it, and "replay" would collapse repeated identical prompts.
                    emit(.userEcho(text: text, imageCount: images, uuid: uuid, isReplay: false), date)
                case .toolResult, .compactSummary: emit(decoded, date)
                default: break
                }
            case "assistant":
                let decoded = InboundDecoder.decode(.object(fields))
                switch decoded {
                case .assistantBlock, .localCommandOutput: emit(decoded, date)
                default: break
                }
            case "system":
                if fields["subtype"]?.stringValue == "compact_boundary" {
                    let meta = fields["compactMetadata"] ?? fields["compact_metadata"]
                    emit(.compactBoundary(preTokens: meta?["preTokens"]?.intValue ?? meta?["pre_tokens"]?.intValue,
                                          postTokens: meta?["postTokens"]?.intValue ?? meta?["post_tokens"]?.intValue), date)
                }
            default: break
            }
        }
        return skipped
    }

    // MARK: Fork points

    /// The `uuid` of the newest assistant record outside a sidechain: what `--resume-session-at` names to fork at "now".
    /// A user record is not used (a prompt the model has not answered yet is not part of the point). Nil when there is none.
    public static func lastMessageUUID(in data: Data) -> String? {
        var end = data.endIndex
        while end > data.startIndex {
            let lineStart = data[data.startIndex..<end].lastIndex(of: UInt8(ascii: "\n")).map { data.index(after: $0) } ?? data.startIndex
            let line = data[lineStart..<end]
            end = lineStart > data.startIndex ? data.index(before: lineStart) : data.startIndex
            if line.isEmpty { continue }
            guard let root = JSONValue.parse(line), root["type"]?.stringValue == "assistant",
                  root["isSidechain"]?.boolValue != true, let uuid = root["uuid"]?.stringValue else { continue }
            return uuid
        }
        return nil
    }

    /// The transcript up to and including the line whose record has this `uuid`; nil when no line has it.
    public static func truncated(_ data: Data, after uuid: String) -> Data? {
        guard let hit = data.range(of: Data("\"uuid\":\"\(uuid)\"".utf8)) else { return nil }
        let end = data[hit.upperBound...].firstIndex(of: UInt8(ascii: "\n")) ?? data.endIndex
        return data[data.startIndex..<end]
    }

    /// Whether some record carries this `uuid`.
    public static func contains(_ data: Data, uuid: String) -> Bool {
        data.range(of: Data("\"uuid\":\"\(uuid)\"".utf8)) != nil
    }
}
