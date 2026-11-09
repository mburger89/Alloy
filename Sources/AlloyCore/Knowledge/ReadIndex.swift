import Foundation

/// One read of (part of) a file by a session, with the file's stamp when the read finished.
public struct ReadEntry: Codable, Sendable, Equatable {
    public var session: UUID
    /// Project-relative.
    public var path: String
    /// The lines the session saw; nil means the whole file.
    public var lines: ClosedRange<Int>?
    public var stamp: FileStamp
    public var date: Date
    /// The session's compaction generation at read time.
    public var generation: Int

    public init(session: UUID, path: String, lines: ClosedRange<Int>?, stamp: FileStamp, date: Date, generation: Int) {
        self.session = session; self.path = path; self.lines = lines; self.stamp = stamp
        self.date = date; self.generation = generation
    }
}

/// Which sessions read which files, and what the files looked like then.
public struct ReadIndex: Codable, Sendable {
    /// Files larger than this are never served from the notes store.
    public static let servableLimit = 1_048_576

    private var byPath: [String: [ReadEntry]] = [:]
    /// How many entries each session holds, so `hasReads(excluding:)` does not scan the index. Rebuilt on decode.
    private var entryCounts: [UUID: Int] = [:]

    private enum CodingKeys: String, CodingKey { case byPath }

    public init() {}

    public init(from decoder: Decoder) throws {
        byPath = try decoder.container(keyedBy: CodingKeys.self).decode([String: [ReadEntry]].self, forKey: .byPath)
        for list in byPath.values { for e in list { entryCounts[e.session, default: 0] += 1 } }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(byPath, forKey: .byPath)
    }

    /// Adds a read. A session keeps entries only for the file's newest stamp; within a stamp and generation,
    /// overlapping or adjacent ranges merge, and an entry from an older generation that the new one covers is dropped.
    public mutating func record(_ entry: ReadEntry) {
        var list = byPath[entry.path] ?? []
        let before = list.count { $0.session == entry.session }
        defer { entryCounts[entry.session, default: 0] += list.count { $0.session == entry.session } - before }
        list.removeAll { $0.session == entry.session && $0.stamp != entry.stamp }
        var merged = entry
        list.removeAll { e in
            guard e.session == entry.session, e.stamp == entry.stamp else { return false }
            if e.generation == entry.generation, let u = Self.union(e.lines, merged.lines) {
                merged.lines = u.lines
                return true
            }
            return e.generation < entry.generation && Self.covers(entry.lines, e.lines)
        }
        list.append(merged)
        byPath[entry.path] = list
    }

    /// The union of two ranges when they overlap or touch (nil lines = whole file absorbs everything).
    private static func union(_ a: ClosedRange<Int>?, _ b: ClosedRange<Int>?) -> (lines: ClosedRange<Int>?, Void)? {
        guard let a, let b else { return (nil, ()) }
        guard a.lowerBound <= b.upperBound &+ 1, b.lowerBound <= a.upperBound &+ 1 else { return nil }
        return (min(a.lowerBound, b.lowerBound)...max(a.upperBound, b.upperBound), ())
    }

    /// Whether `held` (nil = whole file) includes every line of `wanted` (nil = whole file).
    static func covers(_ held: ClosedRange<Int>?, _ wanted: ClosedRange<Int>?) -> Bool {
        guard let held else { return true }
        guard let wanted else { return false }
        return held.lowerBound <= wanted.lowerBound && held.upperBound >= wanted.upperBound
    }

    /// Entries for `path` whose stamp equals `stamp`.
    public func current(path: String, stamp: FileStamp) -> [ReadEntry] {
        (byPath[path] ?? []).filter { $0.stamp == stamp }
    }

    public func readers(path: String) -> [ReadEntry] { byPath[path] ?? [] }

    /// Every entry `session` holds, across all files.
    public func entries(of session: UUID) -> [ReadEntry] {
        byPath.values.flatMap { $0.filter { $0.session == session } }
    }

    /// Whether any session other than `session` has read anything.
    public func hasReads(excluding session: UUID) -> Bool {
        entryCounts.contains { $0.key != session && $0.value > 0 }
    }

    /// A fork starts with what its source had read, stamped with the fork's current compaction generation.
    /// With `fromGeneration`, only entries of that source generation are copied (the rest were compacted away).
    public mutating func copy(from source: UUID, to fork: UUID, generation: Int, fromGeneration: Int? = nil) {
        for (path, list) in byPath {
            let extra = list.filter { $0.session == source && (fromGeneration == nil || $0.generation == fromGeneration) }.map { e -> ReadEntry in
                var c = e; c.session = fork; c.generation = generation; return c
            }
            if !extra.isEmpty { byPath[path] = list + extra; entryCounts[fork, default: 0] += extra.count }
        }
    }

    var isEmpty: Bool { byPath.isEmpty }
}

/// The `reads.json` format. The first version stored a bare `ReadIndex`; loading still accepts that.
struct ReadsFile: Codable {
    var index: ReadIndex
    var generations: [String: Int]

    static func decode(_ data: Data) throws -> ReadsFile {
        let decoder = JSONDecoder()
        if let file = try? decoder.decode(ReadsFile.self, from: data) { return file }
        return ReadsFile(index: try decoder.decode(ReadIndex.self, from: data), generations: [:])
    }
}

extension Workspace {
    /// Keeps the read index and the redundancy counters in step with a session's events. Called from `handle`,
    /// beside `trackShellWindows`. Stamps are read off the main actor through `track`, so `settle()` awaits them.
    func trackReads(_ event: ProcessEvent, session s: Session) {
        guard case .message(let m) = event else { return }
        switch m {
        case .compactBoundary, .conversationReset:
            compactionGeneration[s.id, default: 0] += 1
            persistReads()
        case .assistantBlock(_, .toolUse(let id, let name, let input, _)):
            guard ToolKind.classify(name) == .read, let file = input["file_path"]?.stringValue,
                  judgedReads.insert(id).inserted else { return }
            pendingReadPaths[id] = file
            judgeRead(path: file, requested: Self.requestedRange(input), session: s)
        case .toolResult(let r):
            let pending = pendingReadPaths.removeValue(forKey: r.toolUseID)
            judgedReads.remove(r.toolUseID)
            guard !r.isError else { return }
            var parsed = r.read
            if parsed == nil, let pending {
                parsed = Self.readFromText(r.text, path: pending)
                if parsed == nil, !r.text.isEmpty, !warnedReadFormat, Self.expectsNumberedLines(path: pending, text: r.text) {
                    warnedReadFormat = true
                    report("A Read result had no numbered lines Alloy could parse; those reads are not shared.")
                }
            }
            guard let read = parsed, let entryLines = Self.readLines(read) else { return }
            let sid = s.id, generation = compactionGeneration[s.id, default: 0], date = now(), root = projectRoot
            track { [weak self] in
                let found = await Task.detached { () -> (String, FileStamp)? in
                    guard let rel = ProjectLedger.relativePath(read.filePath, root: root),
                          let stamp = FileStamp.read(read.filePath) else { return nil }
                    return (rel, stamp)
                }.value
                guard let self, let (rel, stamp) = found else { return }
                self.readIndex.record(ReadEntry(session: sid, path: rel, lines: entryLines.range, stamp: stamp,
                                                date: date, generation: generation))
                self.persistReads()
            }
        default:
            break
        }
    }

    /// A subagent's Read result carries no `tool_use_result`, only the numbered text (`<line>\t<text>` per line).
    /// The lines come from those numbers; nothing says whether the CLI cut the file short, so the range is always
    /// explicit and never taken for the whole file.
    private static func readFromText(_ text: String, path: String?) -> ReadResult? {
        guard let path else { return nil }
        var first: Int?, last: Int?
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            guard let tab = line.firstIndex(of: "\t"), let n = Int(line[..<tab]) else { continue }
            if first == nil { first = n }
            last = n
        }
        guard let first, let last else { return nil }
        return ReadResult(filePath: path, startLine: first, numLines: last - first + 1, totalLines: Int.max, truncated: true)
    }

    /// Extensions whose Read result is not `<line>\t<text>` lines (cells, pages, pixels).
    private static let nonTextExtensions: Set<String> = ["ipynb", "pdf", "png", "jpg", "jpeg", "gif", "webp", "bmp", "tiff", "heic", "svg"]

    /// Whether a Read result of this file should have been numbered lines. A notebook, a PDF or an image is not, and the
    /// CLI answers an empty file or an offset past the end with a warning note instead of lines.
    private static func expectsNumberedLines(path: String, text: String) -> Bool {
        if nonTextExtensions.contains((path as NSString).pathExtension.lowercased()) { return false }
        return !text.contains("Warning: the file exists but")
    }

    private struct Covered { var range: ClosedRange<Int>? }

    /// The lines a Read returned (`range` nil for the whole file), or nil when it returned nothing usable.
    private static func readLines(_ r: ReadResult) -> Covered? {
        if r.numLines <= 0 { return r.totalLines > 0 ? nil : Covered(range: nil) }
        let last = r.startLine + r.numLines - 1
        if r.startLine <= 1 && !r.truncated && last >= r.totalLines { return Covered(range: nil) }
        return Covered(range: r.startLine...last)
    }

    /// The lines a Read asks for: nil with neither `offset` nor `limit` (the whole file), else a 1-based range.
    private static func requestedRange(_ input: JSONValue) -> ClosedRange<Int>? {
        let offset = input["offset"]?.intValue, limit = input["limit"]?.intValue
        guard offset != nil || limit != nil else { return nil }
        let start = max(offset ?? 1, 1)
        guard let limit else { return start...Int.max }
        return start...(start &+ max(limit, 1) &- 1)
    }

    /// Decides, from the index as it is now and the file's current stamp, whether this Read repeats one already done.
    private func judgeRead(path file: String, requested: ClosedRange<Int>?, session s: Session) {
        let sid = s.id, generation = compactionGeneration[s.id, default: 0], root = projectRoot
        let snapshot = readIndex
        track { [weak self] in
            let found = await Task.detached { () -> (String, FileStamp)? in
                guard let rel = ProjectLedger.relativePath(file, root: root), let stamp = FileStamp.read(file) else { return nil }
                return (rel, stamp)
            }.value
            guard let self, let (rel, stamp) = found else { return }
            let seen = snapshot.current(path: rel, stamp: stamp).contains {
                ($0.session != sid || $0.generation == generation) && ReadIndex.covers($0.lines, requested)
            }
            if seen || self.hasCurrentNote(rel, stamp) {
                s.redundantReads += 1
                self.redundantReads += 1
            }
        }
    }
}
