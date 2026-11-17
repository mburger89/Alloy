import AlloyCore
import Foundation
import MetalUICodeBuffer

/// The edit a completion item asks for, in byte offsets of the snapshot the request was made for.
public struct CompletionEdit: Sendable, Equatable {
    /// The range replaced when the item is inserted (the `textEdit` range, or an `InsertReplaceEdit`'s `insert`).
    public var insert: Range<Int>
    /// The `InsertReplaceEdit`'s `replace` range, if the server sent one.
    public var replace: Range<Int>?
    public var newText: String

    public init(insert: Range<Int>, replace: Range<Int>? = nil, newText: String) {
        self.insert = insert
        self.replace = replace
        self.newText = newText
    }
}

public struct CompletionItem: Sendable, Equatable {
    public var label: String
    public var detail: String?
    public var kind: Int?
    public var sortText: String?
    public var filterText: String?
    public var insertText: String?
    public var isSnippet: Bool
    public var edit: CompletionEdit?
    public var additionalEdits: [ByteEdit]
    public var commitCharacters: [String]?
    /// Markdown.
    public var documentation: String?
    public var resolveData: JSONValue?
    public var deprecated: Bool

    public init(label: String, detail: String? = nil, kind: Int? = nil, sortText: String? = nil, filterText: String? = nil,
                insertText: String? = nil, isSnippet: Bool = false, edit: CompletionEdit? = nil,
                additionalEdits: [ByteEdit] = [], commitCharacters: [String]? = nil, documentation: String? = nil,
                resolveData: JSONValue? = nil, deprecated: Bool = false) {
        self.label = label
        self.detail = detail
        self.kind = kind
        self.sortText = sortText
        self.filterText = filterText
        self.insertText = insertText
        self.isSnippet = isSnippet
        self.edit = edit
        self.additionalEdits = additionalEdits
        self.commitCharacters = commitCharacters
        self.documentation = documentation
        self.resolveData = resolveData
        self.deprecated = deprecated
    }
}

public struct CompletionList: Sendable, Equatable {
    public var items: [CompletionItem]
    public var isIncomplete: Bool

    public init(items: [CompletionItem], isIncomplete: Bool = false) {
        self.items = items
        self.isIncomplete = isIncomplete
    }
}

public enum CompletionTrigger: Sendable, Equatable {
    case invoked, character(String), incomplete
}

public enum CompletionParsing {
    /// The most items decoded from one answer; a longer list is cut and treated as incomplete.
    public static let itemCap = 5_000

    /// Reads a completion answer (`CompletionItem[]`, a `CompletionList` or `null`) against `snapshot`. A malformed item
    /// is skipped and a malformed edit only drops that item's edit, so a list never fails as a whole. Nil only for an
    /// answer of the wrong shape.
    public static func parse(_ result: JSONValue, encoding: PositionEncoding, snapshot: CodeSnapshot) -> CompletionList? {
        let rawItems: [JSONValue]
        var incomplete = false
        var defaults = Defaults()
        switch result {
        case .null: return CompletionList(items: [])
        case .array(let items): rawItems = items
        case .object:
            guard let items = result["items"]?.arrayValue else { return nil }
            rawItems = items
            incomplete = result["isIncomplete"]?.boolValue ?? false
            defaults = Defaults(result["itemDefaults"], encoding: encoding, snapshot: snapshot)
        default: return nil
        }
        if rawItems.count > itemCap { incomplete = true }
        var items: [CompletionItem] = []
        items.reserveCapacity(min(rawItems.count, itemCap))
        for raw in rawItems.prefix(itemCap) {
            if let item = item(raw, defaults: defaults, encoding: encoding, snapshot: snapshot) { items.append(item) }
        }
        return CompletionList(items: items, isIncomplete: incomplete)
    }

    struct Defaults {
        var commitCharacters: [String]?
        var insertTextFormat: Int?
        var insert: Range<Int>?
        var replace: Range<Int>?

        init() {}

        init(_ value: JSONValue?, encoding: PositionEncoding, snapshot: CodeSnapshot) {
            guard let value, case .object = value else { return }
            commitCharacters = value["commitCharacters"]?.arrayValue?.compactMap(\.stringValue)
            insertTextFormat = value["insertTextFormat"]?.intValue
            if let range = value["editRange"] {
                if range["insert"] != nil {
                    insert = byteRange(range["insert"], encoding: encoding, snapshot: snapshot)
                    replace = byteRange(range["replace"], encoding: encoding, snapshot: snapshot)
                } else {
                    insert = byteRange(range, encoding: encoding, snapshot: snapshot)
                }
            }
        }
    }

    /// A range whose ends must not split a character of the server's encoding; nil otherwise.
    static func byteRange(_ value: JSONValue?, encoding: PositionEncoding, snapshot: CodeSnapshot) -> Range<Int>? {
        guard let lsp = DefinitionParsing.lspRange(value),
              let start = try? TextEditParsing.offset(of: lsp.start, snapshot: snapshot, encoding: encoding),
              let end = try? TextEditParsing.offset(of: lsp.end, snapshot: snapshot, encoding: encoding),
              end >= start else { return nil }
        return start..<end
    }

    static func markdown(_ value: JSONValue?) -> String? {
        guard let value else { return nil }
        let text: String?
        if let string = value.stringValue { text = string } else { text = value["value"]?.stringValue }
        guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return text
    }

    static func item(_ raw: JSONValue, defaults: Defaults, encoding: PositionEncoding, snapshot: CodeSnapshot) -> CompletionItem? {
        guard case .object = raw, let label = raw["label"]?.stringValue else { return nil }
        let format = raw["insertTextFormat"]?.intValue ?? defaults.insertTextFormat
        var edit: CompletionEdit?
        if let textEdit = raw["textEdit"], case .object = textEdit, let newText = textEdit["newText"]?.stringValue {
            if textEdit["insert"] != nil {
                if let insert = byteRange(textEdit["insert"], encoding: encoding, snapshot: snapshot) {
                    edit = CompletionEdit(insert: insert, replace: byteRange(textEdit["replace"], encoding: encoding, snapshot: snapshot),
                                          newText: newText)
                }
            } else if let range = byteRange(textEdit["range"], encoding: encoding, snapshot: snapshot) {
                edit = CompletionEdit(insert: range, newText: newText)
            }
        } else if raw["textEdit"] == nil, let insert = defaults.insert {
            edit = CompletionEdit(insert: insert, replace: defaults.replace,
                                  newText: raw["textEditText"]?.stringValue ?? raw["insertText"]?.stringValue ?? label)
        }
        var additional: [ByteEdit] = []
        if let list = raw["additionalTextEdits"]?.arrayValue, let edits = try? TextEditParsing.byteEdits(list, snapshot: snapshot, encoding: encoding) {
            additional = edits
        }
        let tagged = raw["tags"]?.arrayValue?.contains { $0.intValue == 1 } ?? false
        return CompletionItem(
            label: label,
            detail: raw["detail"]?.stringValue,
            kind: raw["kind"]?.intValue,
            sortText: raw["sortText"]?.stringValue,
            filterText: raw["filterText"]?.stringValue,
            insertText: raw["insertText"]?.stringValue,
            isSnippet: format == 2,
            edit: edit,
            additionalEdits: additional,
            commitCharacters: raw["commitCharacters"]?.arrayValue?.compactMap(\.stringValue) ?? defaults.commitCharacters,
            documentation: markdown(raw["documentation"]),
            resolveData: raw["data"],
            deprecated: tagged || (raw["deprecated"]?.boolValue ?? false))
    }

    /// The item as sent back with `completionItem/resolve`: the fields a server needs to find it again.
    static func wire(_ item: CompletionItem, encoding: PositionEncoding, snapshot: CodeSnapshot) -> JSONValue {
        var object: [String: JSONValue] = ["label": .string(item.label)]
        if let kind = item.kind { object["kind"] = .number(Double(kind)) }
        if let detail = item.detail { object["detail"] = .string(detail) }
        if let sortText = item.sortText { object["sortText"] = .string(sortText) }
        if let filterText = item.filterText { object["filterText"] = .string(filterText) }
        if let insertText = item.insertText { object["insertText"] = .string(insertText) }
        if item.isSnippet { object["insertTextFormat"] = .number(2) }
        if let commit = item.commitCharacters { object["commitCharacters"] = .array(commit.map { .string($0) }) }
        if let data = item.resolveData { object["data"] = data }
        func range(_ r: Range<Int>) -> JSONValue {
            func position(_ o: Int) -> JSONValue {
                let p = Positions.lspPosition(utf8Offset: o, in: snapshot, encoding: encoding)
                return .object(["line": .number(Double(p.line)), "character": .number(Double(p.character))])
            }
            return .object(["start": position(r.lowerBound), "end": position(r.upperBound)])
        }
        if let edit = item.edit {
            if let replace = edit.replace {
                object["textEdit"] = .object(["newText": .string(edit.newText), "insert": range(edit.insert), "replace": range(replace)])
            } else {
                object["textEdit"] = .object(["newText": .string(edit.newText), "range": range(edit.insert)])
            }
        }
        return .object(object)
    }

    /// `original` with what a `completionItem/resolve` answer added: documentation, detail and additional edits.
    static func merge(_ original: CompletionItem, resolved raw: JSONValue, encoding: PositionEncoding,
                      snapshot: CodeSnapshot) -> CompletionItem? {
        guard case .object = raw else { return nil }
        guard let resolved = item(raw, defaults: Defaults(), encoding: encoding, snapshot: snapshot) else { return original }
        var merged = original
        if let detail = resolved.detail { merged.detail = detail }
        if let documentation = resolved.documentation { merged.documentation = documentation }
        if !resolved.additionalEdits.isEmpty { merged.additionalEdits = resolved.additionalEdits }
        return merged
    }
}

extension LSPManager {
    /// Asks the server of `path` for completions at `utf8Offset` of `snapshot`. Times out after 2 s.
    public func completion(path: String, utf8Offset: Int, snapshot: CodeSnapshot,
                           trigger: CompletionTrigger) async -> LSPOutcome<CompletionList> {
        await send(.completion, path: path, snapshot: snapshot, timeout: .seconds(2), params: { uri, encoding in
            var body = Self.textDocumentPosition(uri: uri, offset: utf8Offset, snapshot: snapshot, encoding: encoding)
            var context: [String: JSONValue]
            switch trigger {
            case .invoked: context = ["triggerKind": .number(1)]
            case .character(let c): context = ["triggerKind": .number(2), "triggerCharacter": .string(c)]
            case .incomplete: context = ["triggerKind": .number(3)]
            }
            if case .object(var object) = body { object["context"] = .object(context); body = .object(object) }
            return body
        }, parse: { answer, encoding, snapshot in CompletionParsing.parse(answer, encoding: encoding, snapshot: snapshot) })
    }

    /// Fills in documentation, detail and additional edits of `item`. Times out after 1 s.
    public func resolveCompletion(path: String, item: CompletionItem, snapshot: CodeSnapshot) async -> LSPOutcome<CompletionItem> {
        await send(.completionResolve, path: path, snapshot: snapshot, timeout: .seconds(1),
                   params: { _, encoding in CompletionParsing.wire(item, encoding: encoding, snapshot: snapshot) },
                   parse: { answer, encoding, snapshot in CompletionParsing.merge(item, resolved: answer, encoding: encoding, snapshot: snapshot) })
    }
}
