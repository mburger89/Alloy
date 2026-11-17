import AlloyCore
import Foundation
import MetalUICodeBuffer

/// A language feature asked of a server with a position or document request.
public enum Feature: String, Sendable, CaseIterable {
    case definition, hover, references, documentSymbol, formatting, rangeFormatting

    var method: String {
        switch self {
        case .definition: "textDocument/definition"
        case .hover: "textDocument/hover"
        case .references: "textDocument/references"
        case .documentSymbol: "textDocument/documentSymbol"
        case .formatting: "textDocument/formatting"
        case .rangeFormatting: "textDocument/rangeFormatting"
        }
    }

    func supported(_ caps: ServerCapabilities) -> Bool {
        switch self {
        case .definition: caps.definition
        case .hover: caps.hover
        case .references: caps.references
        case .documentSymbol: caps.documentSymbol
        case .formatting: caps.documentFormatting
        case .rangeFormatting: caps.documentRangeFormatting
        }
    }
}

/// What a kernel request came to.
public enum LSPOutcome<R: Sendable>: Sendable {
    /// The server answered and the answer was read.
    case answered(R)
    /// Nothing was asked: no server, no capability, or the task was cancelled.
    case unavailable
    /// The text moved on (before the request, or the server said the content was modified or the request cancelled).
    case stale
    case timedOut
    case failed(String)
}

extension LSPOutcome: Equatable where R: Equatable {}

/// Which of the features a document's servers offer (the union over its main server and linters).
public struct FeatureSet: Sendable, Equatable {
    public var hover = false
    public var references = false
    public var documentSymbol = false
    public var formatting = false
    public var rangeFormatting = false

    public init(hover: Bool = false, references: Bool = false, documentSymbol: Bool = false,
                formatting: Bool = false, rangeFormatting: Bool = false) {
        self.hover = hover
        self.references = references
        self.documentSymbol = documentSymbol
        self.formatting = formatting
        self.rangeFormatting = rangeFormatting
    }

    public init(_ caps: ServerCapabilities) {
        self.init(hover: caps.hover, references: caps.references, documentSymbol: caps.documentSymbol,
                  formatting: caps.documentFormatting, rangeFormatting: caps.documentRangeFormatting)
    }

    mutating func formUnion(_ other: FeatureSet) {
        hover = hover || other.hover
        references = references || other.references
        documentSymbol = documentSymbol || other.documentSymbol
        formatting = formatting || other.formatting
        rangeFormatting = rangeFormatting || other.rangeFormatting
    }
}

extension LSPManager {
    static let contentModifiedCode = -32801

    /// `TextDocumentPositionParams` for the caret at `offset` of `snapshot`, in the server's `encoding`.
    static func textDocumentPosition(uri: URL, offset: Int, snapshot: CodeSnapshot, encoding: PositionEncoding) -> JSONValue {
        let position = Positions.lspPosition(utf8Offset: offset, in: snapshot, encoding: encoding)
        return .object([
            "textDocument": .object(["uri": .string(uri.absoluteString)]),
            "position": .object(["line": .number(Double(position.line)), "character": .number(Double(position.character))]),
        ])
    }

    /// The one path every feature request takes: target lookup, capability check, waiting until the server has the
    /// text, the version compare, position encoding, cancellation and error mapping. `parse` runs off this actor and
    /// returns nil for an answer it cannot read. Cancelling the calling task cancels the request on the server.
    func send<R: Sendable>(_ feature: Feature, path: String, snapshot: CodeSnapshot, target: RequestTarget? = nil,
                           timeout: Duration,
                           params: @Sendable (_ uri: URL, _ encoding: PositionEncoding) -> JSONValue,
                           parse: @escaping @Sendable (JSONValue, PositionEncoding, CodeSnapshot) -> R?) async -> LSPOutcome<R> {
        guard let target = target ?? requestTarget(path: path) else { return .unavailable }
        // The connection waits for a starting server. The cached capabilities arrive with the `.ready` notice; a request
        // right after the open asks the server itself.
        guard let rpc = try? await target.server.connection(), !Task.isCancelled else { return .unavailable }
        let known = target.capabilities
        let fetched = if let known { known } else { await target.server.capabilities }
        guard let caps = fetched, feature.supported(caps) else { return .unavailable }
        await target.sync.waitUntilSent()
        guard !Task.isCancelled, let now = currentSnapshot(path: path) else { return .unavailable }
        // The position belongs to `snapshot`; if the manager has moved on, it would point elsewhere.
        guard now.version == snapshot.version else { return .stale }
        let encoding = caps.positionEncoding
        let body = params(target.uri, encoding)
        let answer: JSONValue
        do {
            answer = try await rpc.request(feature.method, body, timeout: timeout)
        } catch let error as JSONRPCError {
            if Task.isCancelled { return .unavailable }
            if error.code == JSONRPCError.requestCancelled || error.code == Self.contentModifiedCode { return .stale }
            if error.code == JSONRPCError.timedOut.code { return .timedOut }
            return .failed(error.message)
        } catch {
            return Task.isCancelled ? .unavailable : .failed(String(describing: error))
        }
        guard !Task.isCancelled else { return .unavailable }
        let parsed = await Task.detached { parse(answer, encoding, snapshot) }.value
        guard !Task.isCancelled else { return .unavailable }
        guard let parsed else { return .failed("unreadable answer") }
        return .answered(parsed)
    }
}
