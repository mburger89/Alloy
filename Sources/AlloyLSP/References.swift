import AlloyCore
import Foundation
import MetalUICodeBuffer

/// One place a symbol is used: a project relative path, the range (in the answer's encoding), its zero based line and the
/// trimmed text of that line.
public struct ReferenceHit: Sendable, Equatable {
    public var path: String
    public var range: LSPRange
    public var line: Int
    public var preview: String

    public init(path: String, range: LSPRange, line: Int, preview: String) {
        self.path = path
        self.range = range
        self.line = line
        self.preview = preview
    }
}

/// What a references request answered: the hits inside the project (sorted, capped), how many lay outside it, and the
/// position encoding the hit ranges are in.
public struct ReferenceResult: Sendable, Equatable {
    public var hits: [ReferenceHit]
    public var outsideRoot: Int
    public var truncated: Bool
    public var encoding: PositionEncoding

    public init(hits: [ReferenceHit], outsideRoot: Int, truncated: Bool, encoding: PositionEncoding) {
        self.hits = hits
        self.outsideRoot = outsideRoot
        self.truncated = truncated
        self.encoding = encoding
    }
}

public enum ReferenceParsing {
    public static let hitLimit = 10_000
    public static let previewLimit = 200

    /// Reads a `textDocument/references` result (`Location[]`). Hits under `root` are kept, sorted by path then position
    /// and capped at ``hitLimit``; hits elsewhere are only counted. Previews come from `currentSnapshot` for
    /// `currentPath` (the unsaved text) and from `readLines` for other files (called once per file with the wanted line
    /// numbers; it returns the raw lines it could read, none for a missing or binary file).
    public static func parse(_ result: JSONValue, root: URL, currentPath: String, currentSnapshot: CodeSnapshot,
                             encoding: PositionEncoding = .utf16,
                             readLines: (_ path: String, _ lines: Set<Int>) -> [Int: String]) -> ReferenceResult {
        var found: [(path: String, range: LSPRange)] = []
        var outside = 0
        for item in result.arrayValue ?? [] {
            guard let text = item["uri"]?.stringValue ?? item["targetUri"]?.stringValue, let url = URL(string: text), url.isFileURL,
                  let range = DefinitionParsing.lspRange(item["range"] ?? item["targetSelectionRange"]) else { continue }
            if let path = DefinitionParsing.relativePath(of: url, root: root) { found.append((path, range)) } else { outside += 1 }
        }
        found.sort {
            if $0.path != $1.path { return $0.path < $1.path }
            if $0.range.start.line != $1.range.start.line { return $0.range.start.line < $1.range.start.line }
            return $0.range.start.character < $1.range.start.character
        }
        let truncated = found.count > hitLimit
        if truncated { found.removeLast(found.count - hitLimit) }
        var wanted: [String: Set<Int>] = [:]
        for hit in found where hit.path != currentPath { wanted[hit.path, default: []].insert(hit.range.start.line) }
        var lines: [String: [Int: String]] = [:]
        for (path, set) in wanted { lines[path] = readLines(path, set) }
        let hits = found.map { entry -> ReferenceHit in
            let row = entry.range.start.line
            let raw: String? = entry.path == currentPath
                ? (row >= 0 && row < currentSnapshot.lineCount ? currentSnapshot.line(row) : nil)
                : lines[entry.path]?[row]
            return ReferenceHit(path: entry.path, range: entry.range, line: row, preview: preview(raw))
        }
        return ReferenceResult(hits: hits, outsideRoot: outside, truncated: truncated, encoding: encoding)
    }

    /// `raw` trimmed, at most ``previewLimit`` characters.
    static func preview(_ raw: String?) -> String {
        guard let raw else { return "" }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.count > previewLimit ? String(trimmed.prefix(previewLimit)) : trimmed
    }

    /// The wanted lines of the file at `path` under `root`; none when it is missing, unreadable or binary (a NUL in its
    /// first 8 KiB). Stops scanning after the last wanted line.
    public static func readLines(root: URL, path: String, lines wanted: Set<Int>) -> [Int: String] {
        guard let last = wanted.max(), let data = try? Data(contentsOf: root.appendingPathComponent(path), options: .mappedIfSafe),
              !data.prefix(8192).contains(0) else { return [:] }
        var out: [Int: String] = [:]
        var row = 0
        var start = data.startIndex
        var index = data.startIndex
        while index <= data.endIndex, row <= last {
            if index == data.endIndex || data[index] == 0x0A {
                if wanted.contains(row) {
                    out[row] = String(decoding: data[start..<index], as: UTF8.self)
                }
                row += 1
                start = index + 1
            }
            index += 1
        }
        return out
    }
}

extension LSPManager {
    /// Asks the server of `path` for the uses of the symbol at `utf8Offset` of `snapshot`, its declaration included. Times
    /// out after 10 s; cancelling the calling task cancels the request.
    public func references(path: String, utf8Offset: Int, snapshot: CodeSnapshot) async -> LSPOutcome<ReferenceResult> {
        guard let root = requestTarget(path: path)?.root else { return .unavailable }
        return await send(.references, path: path, snapshot: snapshot, timeout: .seconds(10),
                          params: { uri, encoding in
                              var body = Self.textDocumentPosition(uri: uri, offset: utf8Offset, snapshot: snapshot, encoding: encoding)
                              if case .object(var dict) = body {
                                  dict["context"] = .object(["includeDeclaration": .bool(true)])
                                  body = .object(dict)
                              }
                              return body
                          },
                          parse: { answer, encoding, snapshot in
                              ReferenceParsing.parse(answer, root: root, currentPath: path, currentSnapshot: snapshot, encoding: encoding,
                                                     readLines: { ReferenceParsing.readLines(root: root, path: $0, lines: $1) })
                          })
    }
}
