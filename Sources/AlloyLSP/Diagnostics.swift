import AlloyCore
import Foundation
import MetalUICodeBuffer
import Observation

/// LSP diagnostic severity, with the protocol's numbers.
public enum Severity: Int, Sendable {
    case error = 1, warning, information, hint
}

/// One diagnostic of a document, as UTF-8 byte offsets into the version it was published for.
public struct LSPDiagnostic: Sendable, Equatable {
    public var range: Range<Int>
    public var severity: Severity
    public var message: String
    public var source: String?

    public init(range: Range<Int>, severity: Severity, message: String, source: String? = nil) {
        self.range = range
        self.severity = severity
        self.message = message
        self.source = source
    }
}

/// Turns the `diagnostics` of a `publishDiagnostics` (or a pull report) into byte ranges.
public enum DiagnosticMapping {
    /// Converts `raw` with the snapshot of the version the server reported: the position encoding applies to that text,
    /// not to the current one. A report without a version uses `current`. A report for a version `sync` no longer keeps
    /// (more than `DocumentSync.historyLimit` sends ago, or a closed document) returns nil: it cannot be placed.
    public static func map(_ raw: [JSONValue], version: Int?, sync: DocumentSync, uri: URL,
                           current: CodeSnapshot) async -> [LSPDiagnostic]? {
        let snapshot: CodeSnapshot
        if let version {
            guard let kept = await sync.snapshot(for: uri, version: version) else { return nil }
            snapshot = kept
        } else {
            snapshot = current
        }
        let encoding = await sync.positionEncoding()
        return convert(raw, in: snapshot, encoding: encoding)
    }

    /// The diagnostics of `raw` as UTF-8 ranges of `snapshot`, sorted by start. An empty range is widened to the
    /// character after it (or before it at the end of a line) so it can be seen.
    public static func convert(_ raw: [JSONValue], in snapshot: CodeSnapshot, encoding: PositionEncoding) -> [LSPDiagnostic] {
        var result: [LSPDiagnostic] = []
        for item in raw {
            guard let range = item["range"], let start = position(range["start"]), let end = position(range["end"]) else { continue }
            var bytes = Positions.utf8Range(of: LSPRange(start: start, end: end), in: snapshot, encoding: encoding)
            if bytes.isEmpty { bytes = widened(bytes.lowerBound, in: snapshot) }
            let severity = item["severity"]?.intValue.flatMap(Severity.init(rawValue:)) ?? .error
            result.append(LSPDiagnostic(range: bytes, severity: severity, message: item["message"]?.stringValue ?? "",
                                        source: item["source"]?.stringValue))
        }
        return result.enumerated().sorted { ($0.element.range.lowerBound, $0.offset) < ($1.element.range.lowerBound, $1.offset) }
            .map(\.element)
    }

    private static func position(_ value: JSONValue?) -> LSPPosition? {
        guard let line = value?["line"]?.intValue, let character = value?["character"]?.intValue else { return nil }
        return LSPPosition(line: line, character: character)
    }

    /// The scalar after `offset` on its line, else the one before it; `offset..<offset` for an empty line.
    private static func widened(_ offset: Int, in snapshot: CodeSnapshot) -> Range<Int> {
        let line = snapshot.lineRange(snapshot.point(at: offset).row)
        if offset < line.upperBound {
            let lead = snapshot.utf8(in: offset..<(offset + 1))[0]
            let length = lead >= 0xF0 ? 4 : lead >= 0xE0 ? 3 : lead >= 0xC0 ? 2 : 1
            return offset..<min(line.upperBound, offset + length)
        }
        if offset > line.lowerBound {
            var start = offset - 1
            while start > line.lowerBound, snapshot.utf8(in: start..<(start + 1))[0] & 0xC0 == 0x80 { start -= 1 }
            return start..<offset
        }
        return offset..<offset
    }
}

/// The error and warning counts of one file. Observable on its own, so a view of one path re-runs only for that path.
@MainActor @Observable
public final class DiagnosticCount {
    public internal(set) var errors = 0
    public internal(set) var warnings = 0
    init() {}
}

/// The counts the file panel shows, one observable per path. A box changes only when that file's error or warning
/// count really changes, never per publish and never for another file.
@MainActor
public final class DiagnosticCountsModel {
    @ObservationIgnored private var boxes: [String: DiagnosticCount] = [:]

    public init() {}

    /// The counts of `path`; created empty on first ask so a view can observe a file that has no diagnostics yet.
    public func counts(for path: String) -> DiagnosticCount {
        if let box = boxes[path] { return box }
        let box = DiagnosticCount()
        boxes[path] = box
        return box
    }

    /// The files with any error or warning, for tests and tooling. Reads every box, so it is not for view bodies.
    public var byPath: [String: (errors: Int, warnings: Int)] {
        boxes.compactMapValues { $0.errors == 0 && $0.warnings == 0 ? nil : ($0.errors, $0.warnings) }
    }

    func set(path: String, errors: Int, warnings: Int) {
        guard errors != 0 || warnings != 0 || boxes[path] != nil else { return }
        let box = counts(for: path)
        if box.errors != errors { box.errors = errors }
        if box.warnings != warnings { box.warnings = warnings }
    }

    func removeAll() {
        for path in boxes.keys { set(path: path, errors: 0, warnings: 0) }
    }
}

/// The latest diagnostics per path, as the main actor holds them for painting and navigation. Not observable: only
/// ``counts`` is.
@MainActor
public final class DiagnosticStore {
    public struct Entry: Sendable {
        /// The buffer version the ranges are for.
        public var version: Int?
        public var items: [LSPDiagnostic]

        public init(version: Int?, items: [LSPDiagnostic]) {
            self.version = version
            self.items = items
        }
    }

    public let counts = DiagnosticCountsModel()
    private var entries: [String: Entry] = [:]

    public init() {}

    public func entry(for path: String) -> Entry? { entries[path] }

    public func set(path: String, version: Int?, items: [LSPDiagnostic]) {
        entries[path] = Entry(version: version, items: items)
        counts.set(path: path,
                   errors: items.filter { $0.severity == .error }.count,
                   warnings: items.filter { $0.severity == .warning }.count)
    }

    /// Forgets `path`; true when it held anything.
    @discardableResult
    public func remove(path: String) -> Bool {
        counts.set(path: path, errors: 0, warnings: 0)
        return entries.removeValue(forKey: path) != nil
    }

    public func removeAll() {
        entries = [:]
        counts.removeAll()
    }
}
