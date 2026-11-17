import AlloyCore
import Foundation
import MetalUICodeBuffer

/// One text replacement in UTF-8 byte offsets of the text it was computed for.
public struct ByteEdit: Sendable, Equatable {
    public var range: Range<Int>
    public var text: String

    public init(range: Range<Int>, text: String) {
        self.range = range
        self.text = text
    }
}

/// The edits one file of a workspace edit asks for. `version` is the document version the server computed them
/// against (nil: it did not say). `edits` are sorted by start and do not overlap.
public struct FileEdits: Sendable, Equatable {
    public var path: String
    public var version: Int?
    public var edits: [ByteEdit]

    public init(path: String, version: Int?, edits: [ByteEdit]) {
        self.path = path
        self.version = version
        self.edits = edits
    }
}

/// Why a server's edit was refused. The whole edit is refused, never a part of it.
public enum EditRejection: Error, Equatable, Sendable {
    case invalid(String), outsideRoot(String), resourceOperation, overlap(String)

    public var message: String {
        switch self {
        case .invalid: "The language server sent an invalid edit"
        case .outsideRoot: "The language server sent an edit outside the project"
        case .resourceOperation: "The language server asked to create, rename or delete files, which Alloy does not do"
        case .overlap: "The language server sent overlapping edits"
        }
    }
}

public enum TextEditParsing {
    /// Reads `TextEdit`s against `snapshot`. A line past the end clamps to the end of the text and a character past a
    /// line's content to the content end; a position inside a UTF-16 surrogate pair or a UTF-8 sequence is `.invalid`.
    /// The result is sorted by start (equal starts keep the server's order) and rejected when ranges overlap.
    public static func byteEdits(_ textEdits: [JSONValue], snapshot: CodeSnapshot,
                                 encoding: PositionEncoding) throws(EditRejection) -> [ByteEdit] {
        var edits: [ByteEdit] = []
        edits.reserveCapacity(textEdits.count)
        for item in textEdits {
            guard let text = item["newText"]?.stringValue, let range = DefinitionParsing.lspRange(item["range"]) else {
                throw .invalid("malformed TextEdit")
            }
            let start = try offset(of: range.start, snapshot: snapshot, encoding: encoding)
            let end = try offset(of: range.end, snapshot: snapshot, encoding: encoding)
            guard end >= start else { throw .invalid("range ends before it starts") }
            edits.append(ByteEdit(range: start..<end, text: text))
        }
        // `sorted` is not stable, so the array index breaks ties.
        let sorted = edits.enumerated().sorted {
            $0.element.range.lowerBound != $1.element.range.lowerBound
                ? $0.element.range.lowerBound < $1.element.range.lowerBound : $0.offset < $1.offset
        }.map(\.element)
        for (previous, next) in zip(sorted, sorted.dropFirst()) where next.range.lowerBound < previous.range.upperBound {
            throw .overlap("\(previous.range) and \(next.range)")
        }
        return sorted
    }

    /// The byte offset of `position`, or `.invalid` when it splits a character of the server's encoding.
    static func offset(of position: LSPPosition, snapshot: CodeSnapshot,
                       encoding: PositionEncoding) throws(EditRejection) -> Int {
        guard position.line < snapshot.lineCount else { return snapshot.utf8Count }
        let line = snapshot.lineRange(max(0, position.line))
        let character = max(0, position.character)
        switch encoding {
        case .utf8:
            let o = line.lowerBound + character
            if o >= line.upperBound { return line.upperBound }
            if let byte = snapshot.utf8(in: o..<(o + 1)).first, byte & 0xC0 == 0x80 { throw .invalid("inside a UTF-8 sequence") }
            return o
        case .utf16:
            let base = snapshot.utf16Offset(ofUTF8: line.lowerBound)
            let o = snapshot.utf8Offset(ofUTF16: base + character)
            if o >= line.upperBound { return line.upperBound }
            guard snapshot.utf16Offset(ofUTF8: o) - base == character else { throw .invalid("inside a surrogate pair") }
            return o
        case .utf32:
            let base = snapshot.scalarOffset(ofUTF8: line.lowerBound)
            let o = snapshot.utf8Offset(ofScalar: base + character)
            return min(o, line.upperBound)
        }
    }
}

public enum WorkspaceEditParsing {
    /// Reads a `WorkspaceEdit` into per-file byte edits, in the order the files first appear. Only text edits are
    /// supported: any file operation is `.resourceOperation`, a URI outside `root` is `.outsideRoot`. Annotations are
    /// ignored. `snapshot` gives the text of a project-relative path (nil when it cannot be read).
    public static func normalize(_ edit: JSONValue, root: URL, encoding: PositionEncoding,
                                 snapshot: (String) -> CodeSnapshot?) throws(EditRejection) -> [FileEdits] {
        var order: [String] = []
        var versions: [String: Int] = [:]
        var pending: [String: [JSONValue]] = [:]

        func add(uri: String, version: Int?, edits: [JSONValue]) throws(EditRejection) {
            guard let url = URL(string: uri), url.isFileURL else { throw .invalid("not a file URI") }
            guard let path = DefinitionParsing.relativePath(of: url, root: root) else { throw .outsideRoot(uri) }
            if pending[path] == nil { order.append(path) }
            pending[path, default: []].append(contentsOf: edits)
            if let version { versions[path] = version }
        }

        if let changes = edit["documentChanges"]?.arrayValue {
            for change in changes {
                if change["kind"]?.stringValue != nil { throw .resourceOperation }
                guard let uri = change["textDocument"]?["uri"]?.stringValue, let edits = change["edits"]?.arrayValue else {
                    throw .invalid("malformed documentChanges entry")
                }
                try add(uri: uri, version: change["textDocument"]?["version"]?.intValue, edits: edits)
            }
        } else if let changes = edit["changes"]?.objectValue {
            for uri in changes.keys.sorted() {
                guard let edits = changes[uri]?.arrayValue else { throw .invalid("malformed changes entry") }
                try add(uri: uri, version: nil, edits: edits)
            }
        }
        var out: [FileEdits] = []
        for path in order {
            guard let text = snapshot(path) else { throw .invalid("cannot read \(path)") }
            out.append(FileEdits(path: path, version: versions[path],
                                 edits: try TextEditParsing.byteEdits(pending[path] ?? [], snapshot: text, encoding: encoding)))
        }
        return out
    }
}
