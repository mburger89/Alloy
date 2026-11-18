import AlloyCore
import Foundation
import MetalUICodeBuffer

/// What a `textDocument/prepareRename` answered. A nil `range` means the server said "use your default behaviour" (or its
/// range did not convert): the caller picks the word at the caret.
public struct PrepareRenameInfo: Sendable, Equatable {
    public var range: Range<Int>?
    public var placeholder: String?

    public init(range: Range<Int>? = nil, placeholder: String? = nil) {
        self.range = range
        self.placeholder = placeholder
    }
}

/// The raw `WorkspaceEdit` a `textDocument/rename` answered, with the encoding its positions are in; the caller
/// normalizes it with `WorkspaceEditParsing`.
public struct RenameAnswer: Sendable, Equatable {
    public var edit: JSONValue
    public var encoding: PositionEncoding

    public init(edit: JSONValue, encoding: PositionEncoding) {
        self.edit = edit
        self.encoding = encoding
    }
}

public enum RenameParsing {
    /// Reads a `prepareRename` result: a `Range`, `{range, placeholder}` or `{defaultBehavior: true}`. `null` and anything
    /// unreadable give nil ("cannot rename here"). A range that does not convert (it splits a character) gives a nil range.
    public static func prepare(_ result: JSONValue, encoding: PositionEncoding, snapshot: CodeSnapshot) -> PrepareRenameInfo? {
        guard case .object = result else { return nil }
        if result["start"] != nil {
            return PrepareRenameInfo(range: CompletionParsing.byteRange(result, encoding: encoding, snapshot: snapshot))
        }
        if result["range"] != nil {
            return PrepareRenameInfo(range: CompletionParsing.byteRange(result["range"], encoding: encoding, snapshot: snapshot),
                                     placeholder: result["placeholder"]?.stringValue)
        }
        if result["defaultBehavior"]?.boolValue == true { return PrepareRenameInfo() }
        return nil
    }
}

extension LSPManager {
    /// Asks whether the symbol at `utf8Offset` of `snapshot` can be renamed, and which text it covers. `.answered(nil)` is
    /// "cannot rename here". Times out after 10 s; cancelling the calling task cancels the request.
    public func prepareRename(path: String, utf8Offset: Int, snapshot: CodeSnapshot) async -> LSPOutcome<PrepareRenameInfo?> {
        await send(.prepareRename, path: path, snapshot: snapshot, timeout: .seconds(10),
                   params: { uri, encoding in Self.textDocumentPosition(uri: uri, offset: utf8Offset, snapshot: snapshot, encoding: encoding) },
                   parse: { answer, encoding, snapshot -> PrepareRenameInfo?? in .some(RenameParsing.prepare(answer, encoding: encoding, snapshot: snapshot)) })
    }

    /// Asks the server to rename the symbol at `utf8Offset` of `snapshot` to `newName`. A null answer is `.answered(nil)`;
    /// a server error is `.failed` with its message. Times out after 10 s.
    public func rename(path: String, utf8Offset: Int, newName: String, snapshot: CodeSnapshot) async -> LSPOutcome<RenameAnswer?> {
        await send(.rename, path: path, snapshot: snapshot, timeout: .seconds(10),
                   params: { uri, encoding in
                       var params = Self.textDocumentPosition(uri: uri, offset: utf8Offset, snapshot: snapshot, encoding: encoding)
                       if case .object(var object) = params {
                           object["newName"] = .string(newName)
                           params = .object(object)
                       }
                       return params
                   },
                   parse: { answer, encoding, _ -> RenameAnswer?? in
                       guard case .object = answer else { return .some(nil) }
                       return .some(RenameAnswer(edit: answer, encoding: encoding))
                   })
    }
}
