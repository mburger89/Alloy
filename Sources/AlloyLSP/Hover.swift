import AlloyCore
import Foundation
import MetalUICodeBuffer

/// What a `textDocument/hover` answered: Markdown text and the byte range of the text it describes, if the server said.
public struct HoverInfo: Sendable, Equatable {
    public var markdown: String
    public var range: Range<Int>?

    public init(markdown: String, range: Range<Int>? = nil) {
        self.markdown = markdown
        self.range = range
    }
}

public enum HoverParsing {
    /// Reads a hover result: `contents` as `MarkupContent`, a `MarkedString` or an array of them (a `{language,value}`
    /// becomes a fenced block); the optional `range` is converted with `encoding` against `snapshot` (the text the request
    /// was made for). `null`, no contents, or contents that are blank give nil.
    public static func parse(_ result: JSONValue, encoding: PositionEncoding, snapshot: CodeSnapshot) -> HoverInfo? {
        guard case .object = result, let contents = result["contents"] else { return nil }
        let parts: [String]
        if let array = contents.arrayValue { parts = array.compactMap(markdown(of:)) } else { parts = [markdown(of: contents)].compactMap { $0 } }
        let text = parts.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.joined(separator: "\n\n")
        guard !text.isEmpty else { return nil }
        var range: Range<Int>?
        if let lsp = DefinitionParsing.lspRange(result["range"]) {
            range = Positions.utf8Range(of: lsp, in: snapshot, encoding: encoding)
        }
        return HoverInfo(markdown: text, range: range)
    }

    /// One `MarkupContent` or `MarkedString`.
    private static func markdown(of value: JSONValue) -> String? {
        if let text = value.stringValue { return text }
        guard case .object = value, let text = value["value"]?.stringValue else { return nil }
        if let language = value["language"]?.stringValue {
            return "```\(language)\n\(text)\n```"
        }
        return text
    }
}

extension LSPManager {
    /// Asks the server of `path` what the symbol at `utf8Offset` of `snapshot` is. A server that has nothing to say answers
    /// `.answered(nil)`. Times out after 2 s; cancelling the calling task cancels the request.
    public func hover(path: String, utf8Offset: Int, snapshot: CodeSnapshot) async -> LSPOutcome<HoverInfo?> {
        await send(.hover, path: path, snapshot: snapshot, timeout: .seconds(2),
                   params: { uri, encoding in Self.textDocumentPosition(uri: uri, offset: utf8Offset, snapshot: snapshot, encoding: encoding) },
                   parse: { answer, encoding, snapshot -> HoverInfo?? in .some(HoverParsing.parse(answer, encoding: encoding, snapshot: snapshot)) })
    }
}
