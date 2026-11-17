import AlloyCore
import Foundation
import MetalUICodeBuffer

/// One entry of a document's outline.
public struct DocSymbol: Sendable, Equatable {
    public var name: String
    public var detail: String?
    /// The LSP `SymbolKind` number.
    public var kind: Int
    /// Nesting level in a hierarchical answer; 0 in a flat one.
    public var depth: Int
    /// The symbol's selection range (its name) as bytes of the request's snapshot.
    public var range: Range<Int>

    public init(name: String, detail: String? = nil, kind: Int, depth: Int, range: Range<Int>) {
        self.name = name
        self.detail = detail
        self.kind = kind
        self.depth = depth
        self.range = range
    }
}

public enum SymbolParsing {
    /// The most symbols read from one answer.
    public static let limit = 5_000

    /// Reads a `textDocument/documentSymbol` result: `DocumentSymbol[]` (flattened pre-order with `depth`) or
    /// `SymbolInformation[]` (depth 0, `containerName` as the detail). Ranges are converted with `encoding` against
    /// `snapshot`. `null`, `[]` and anything unreadable give an empty list; at most ``limit`` symbols are kept.
    public static func parse(_ result: JSONValue, encoding: PositionEncoding, snapshot: CodeSnapshot) -> [DocSymbol] {
        guard let items = result.arrayValue else { return [] }
        var out: [DocSymbol] = []
        // Explicit stack: a hostile answer could nest deeper than the call stack.
        var stack: [(JSONValue, Int)] = items.reversed().map { ($0, 0) }
        while let (item, depth) = stack.popLast(), out.count < limit {
            guard case .object = item, let name = item["name"]?.stringValue else { continue }
            let kind = item["kind"]?.intValue ?? 0
            let detail: String?
            let lsp: LSPRange?
            if let location = item["location"] {
                detail = item["containerName"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 }
                lsp = DefinitionParsing.lspRange(location["range"])
            } else {
                detail = item["detail"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 }
                lsp = DefinitionParsing.lspRange(item["selectionRange"] ?? item["range"])
            }
            if let lsp {
                out.append(DocSymbol(name: name, detail: detail, kind: kind, depth: depth,
                                     range: Positions.utf8Range(of: lsp, in: snapshot, encoding: encoding)))
            }
            if let children = item["children"]?.arrayValue {
                for child in children.reversed() { stack.append((child, depth + 1)) }
            }
        }
        return out
    }
}

extension LSPManager {
    /// Asks the server of `path` for the outline of `snapshot`. Times out after 10 s; cancelling the calling task cancels
    /// the request.
    public func documentSymbols(path: String, snapshot: CodeSnapshot) async -> LSPOutcome<[DocSymbol]> {
        await send(.documentSymbol, path: path, snapshot: snapshot, timeout: .seconds(10),
                   params: { uri, _ in .object(["textDocument": .object(["uri": .string(uri.absoluteString)])]) },
                   parse: { answer, encoding, snapshot in SymbolParsing.parse(answer, encoding: encoding, snapshot: snapshot) })
    }
}
