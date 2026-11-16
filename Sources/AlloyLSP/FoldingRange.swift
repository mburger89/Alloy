import AlloyCore
import Foundation
import MetalUICodeBuffer

/// Reads a `textDocument/foldingRange` result into line ranges.
public enum FoldingRangeParsing {
    /// `FoldingRange[]` (`startLine`, `endLine`; other fields are ignored). `null` or a non-array gives `[]`,
    /// items missing a line are skipped, and the rest is clamped, deduplicated and sorted by
    /// `FoldMerge.normalized`.
    public static func parse(_ result: JSONValue, lineCount: Int) -> [FoldRange] {
        guard let items = result.arrayValue else { return [] }
        let ranges: [FoldRange] = items.compactMap { item in
            guard let start = item["startLine"]?.intValue, let end = item["endLine"]?.intValue else { return nil }
            return FoldRange(startLine: start, endLine: end)
        }
        return FoldMerge.normalized(ranges, lineCount: lineCount)
    }
}

public enum FoldingOutcome: Sendable, Equatable {
    /// The server answered (possibly with no ranges).
    case answered([FoldRange])
    /// The document moved on before the request could be made.
    case stale
    /// Nothing was asked or nothing came back: no server, no support, an error, or the task was cancelled.
    case unavailable
}

extension LSPManager {
    /// Asks the server of `path` for the folding ranges of `snapshot`. Returns once the server has that text; `.stale`
    /// when the document changed since, `.unavailable` without a server, support, an answer, or when cancelled (which
    /// also cancels the request on the server).
    public func foldingRanges(path: String, snapshot: CodeSnapshot) async -> FoldingOutcome {
        guard let target = requestTarget(path: path) else { return .unavailable }
        guard let rpc = try? await target.server.connection(), !Task.isCancelled,
              let caps = await target.server.capabilities, caps.foldingRange else { return .unavailable }
        await target.sync.waitUntilSent()
        guard !Task.isCancelled, let now = requestTarget(path: path) else { return .unavailable }
        guard now.snapshot.version == snapshot.version else { return .stale }
        guard let answer = await requestFoldingRanges(rpc: rpc, uri: target.uri), !Task.isCancelled else { return .unavailable }
        return .answered(FoldingRangeParsing.parse(answer, lineCount: snapshot.lineCount))
    }

    /// The single place that names the wire method; replace this body to move onto a generic request kernel.
    private func requestFoldingRanges(rpc: JSONRPCConnection, uri: URL) async -> JSONValue? {
        let params: JSONValue = .object(["textDocument": .object(["uri": .string(uri.absoluteString)])])
        return try? await rpc.request("textDocument/foldingRange", params)
    }
}
