import AlloyCore
import Foundation
import MetalUICodeBuffer

/// Where a go-to-definition request led: a file of the workspace (project relative path), or one outside it.
public enum DefinitionTarget: Sendable, Equatable {
    case inWorkspace(path: String, range: LSPRange)
    case external(url: URL, range: LSPRange)
}

/// What a definition request answered: the targets, and the position encoding their ranges are in.
public struct DefinitionResult: Sendable, Equatable {
    public var targets: [DefinitionTarget]
    public var encoding: PositionEncoding

    public init(targets: [DefinitionTarget], encoding: PositionEncoding) {
        self.targets = targets
        self.encoding = encoding
    }
}

public enum DefinitionParsing {
    /// Reads a `textDocument/definition` result: `Location`, `Location[]` or `LocationLink[]` (whose
    /// `targetSelectionRange` is used). A target under `root` is in the workspace; any other is external.
    public static func parse(_ result: JSONValue, root: URL) -> [DefinitionTarget] {
        let items: [JSONValue]
        if let array = result.arrayValue { items = array } else if case .object = result { items = [result] } else { items = [] }
        return items.compactMap { item in
            let uriText = item["targetUri"]?.stringValue ?? item["uri"]?.stringValue
            let rangeValue = item["targetSelectionRange"] ?? item["targetRange"] ?? item["range"]
            guard let uriText, let url = URL(string: uriText), url.isFileURL, let range = lspRange(rangeValue) else { return nil }
            if let path = relativePath(of: url, root: root) { return .inWorkspace(path: path, range: range) }
            return .external(url: url.standardizedFileURL, range: range)
        }
    }

    static func lspRange(_ value: JSONValue?) -> LSPRange? {
        guard let value, let sl = value["start"]?["line"]?.intValue, let sc = value["start"]?["character"]?.intValue,
              let el = value["end"]?["line"]?.intValue, let ec = value["end"]?["character"]?.intValue else { return nil }
        return LSPRange(start: LSPPosition(line: sl, character: sc), end: LSPPosition(line: el, character: ec))
    }

    /// `url` relative to `root` (compared both lexically and with symlinks resolved); nil outside it.
    static func relativePath(of url: URL, root: URL) -> String? {
        for (file, base) in [(url.standardizedFileURL, root.standardizedFileURL),
                             (url.resolvingSymlinksInPath(), root.resolvingSymlinksInPath())] {
            let prefix = base.path.hasSuffix("/") ? base.path : base.path + "/"
            if file.path.hasPrefix(prefix), file.path.count > prefix.count { return String(file.path.dropFirst(prefix.count)) }
        }
        return nil
    }
}

/// What a definition request came to.
public enum DefinitionOutcome: Sendable, Equatable {
    /// The server answered (possibly with no target).
    case answered(DefinitionResult)
    /// The document changed after the caret was read, so the position no longer fits; the answer would be for other text.
    case stale
    /// Nothing was asked or nothing came back: no server, no support, an error, or the task was cancelled.
    case unavailable
}

extension LSPManager {
    /// Asks the server of `path` where the symbol at `utf8Offset` of `snapshot` is defined. Returns once the server has
    /// the text the position refers to; empty when it has none, a different text (the document changed since), no
    /// definition support, an error, or the task was cancelled (which also cancels the request on the server).
    func definition(path: String, utf8Offset: Int, snapshot: CodeSnapshot) async -> [DefinitionTarget] {
        if case .answered(let result) = await definitionOutcome(path: path, utf8Offset: utf8Offset, snapshot: snapshot) {
            return result.targets
        }
        return []
    }

    /// ``definition(path:utf8Offset:snapshot:)`` with the position encoding of the answer, and `.stale` when the document
    /// moved on before the request could be made.
    public func definitionOutcome(path: String, utf8Offset: Int, snapshot: CodeSnapshot) async -> DefinitionOutcome {
        guard let target = requestTarget(path: path) else { return .unavailable }
        guard let rpc = try? await target.server.connection(), !Task.isCancelled,
              let caps = await target.server.capabilities, caps.definition else { return .unavailable }
        await target.sync.waitUntilSent()
        // The caret belongs to `snapshot`; if the manager has moved on, the position would point elsewhere.
        guard !Task.isCancelled, let now = requestTarget(path: path) else { return .unavailable }
        guard now.snapshot.version == snapshot.version else { return .stale }
        let position = Positions.lspPosition(utf8Offset: utf8Offset, in: snapshot, encoding: caps.positionEncoding)
        let params: JSONValue = .object([
            "textDocument": .object(["uri": .string(target.uri.absoluteString)]),
            "position": .object(["line": .number(Double(position.line)), "character": .number(Double(position.character))]),
        ])
        guard let answer = try? await rpc.request("textDocument/definition", params), !Task.isCancelled else { return .unavailable }
        return .answered(DefinitionResult(targets: DefinitionParsing.parse(answer, root: target.root), encoding: caps.positionEncoding))
    }
}
