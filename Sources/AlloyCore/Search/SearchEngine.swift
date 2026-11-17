import Foundation
import MetalUICodeBuffer

/// Limits that bound a project search. The defaults are the product values; tests shrink them.
public struct SearchLimits: Sendable, Equatable {
    /// Files larger than this are skipped (the editor's own preview limit).
    public var maxFileBytes = 16 * 1024 * 1024
    /// A file with a NUL byte in its first `binaryProbe` bytes is binary and skipped.
    public var binaryProbe = 8 * 1024
    public var workers = 4
    /// Files over this size are read one at a time.
    public var largeFileBytes = 4 * 1024 * 1024
    public var maxFiles = 2_000
    public var regexBudget: Duration = .milliseconds(250)
    public var flushInterval: Duration = .milliseconds(50)
    public var flushMatches = 500
    /// Workers pause while this many files ahead of the oldest unfinished one.
    public var reorderWindow = 256

    public init() {}
}

public struct SearchFileResult: Sendable, Equatable {
    /// Position among the paths that passed the include/exclude filter; results arrive in increasing order.
    public var index: Int
    public var path: String
    public var matches: [SearchMatch]
    /// False when the file is not valid UTF-8 (a replace into it must be refused).
    public var isUTF8: Bool

    public init(index: Int, path: String, matches: [SearchMatch], isUTF8: Bool) {
        self.index = index; self.path = path; self.matches = matches; self.isUTF8 = isUTF8
    }
}

public struct SearchSummaryFacts: Sendable, Equatable {
    public var totalMatches = 0
    public var totalFiles = 0
    public var cappedMatches = false
    public var cappedFiles = false
    /// Files not searched: binary, too large, unreadable, regex lines or budget exceeded.
    public var skipped = 0
    public var indexTruncated = false
    /// Nothing matched, but the regex matched the empty string somewhere.
    public var onlyEmptyMatches = false

    public init() {}
}

public struct SearchBatch: Sendable {
    public var files: [SearchFileResult]
    /// Set on the last batch only.
    public var finished: SearchSummaryFacts?

    public init(files: [SearchFileResult], finished: SearchSummaryFacts? = nil) {
        self.files = files; self.finished = finished
    }
}

/// Streams project search results over a list of relative paths. UI-free: the model drives it.
public actor SearchEngine {
    private let root: URL
    private let limits: SearchLimits
    private var gate: (@Sendable (String) async -> Void)?

    public init(root: URL, limits: SearchLimits = SearchLimits()) {
        self.root = root
        self.limits = limits
    }

    /// Test hook: awaited by a worker before it scans a path.
    public func setScanGate(_ gate: (@Sendable (String) async -> Void)?) { self.gate = gate }

    /// Scans `paths` in order with up to four workers and yields batches in path order. `overlays` (open documents'
    /// snapshots, by relative path) win over the disk. An empty or invalid query yields one empty finished batch
    /// (callers validate with `SearchQuery.compile()` first to show the message). Cancelling the consumer stops the scan.
    public func run(_ query: SearchQuery, paths: [String], indexTruncated: Bool, overlays: [String: CodeSnapshot],
                    extraExclude: [String], maxResults: Int) -> AsyncStream<SearchBatch> {
        let root = root, limits = limits, gate = gate
        return AsyncStream(bufferingPolicy: .unbounded) { continuation in
            var empty = SearchSummaryFacts()
            empty.indexTruncated = indexTruncated
            guard let matcher = try? query.compile() else {
                continuation.yield(SearchBatch(files: [], finished: empty))
                continuation.finish()
                return
            }
            let filter = GlobFilter(include: query.include, exclude: query.exclude, extraExclude: extraExclude)
            let task = Task.detached(priority: .userInitiated) {
                let selected = paths.filter { filter.allows($0) }
                await Self.produce(matcher: matcher, regex: matcher.isRegex, paths: selected, root: root, overlays: overlays,
                                   limits: limits, maxResults: maxResults, indexTruncated: indexTruncated, gate: gate,
                                   continuation: continuation)
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: Producer

    private enum Event: Sendable {
        case file(FileOutcome)
        case tick
    }

    private struct FileOutcome: Sendable {
        var index: Int
        var path: String
        var matches: [SearchMatch] = []
        var isUTF8 = true
        var skipped = false
        var sawOnlyEmpty = false
    }

    private static func produce(matcher: SearchMatcher, regex: Bool, paths: [String], root: URL,
                                overlays: [String: CodeSnapshot], limits: SearchLimits, maxResults: Int,
                                indexTruncated: Bool, gate: (@Sendable (String) async -> Void)?,
                                continuation: AsyncStream<SearchBatch>.Continuation) async {
        var facts = SearchSummaryFacts()
        facts.indexTruncated = indexTruncated
        let large = AsyncSemaphore()
        var pending: [SearchFileResult] = []
        var pendingMatches = 0
        var anyEmpty = false

        func flush() {
            guard !pending.isEmpty else { return }
            continuation.yield(SearchBatch(files: pending))
            pending = []
            pendingMatches = 0
        }

        await withTaskGroup(of: Event.self) { group in
            var next = 0            // next path to schedule
            var emit = 0            // next index to hand to the batcher
            var inFlight = 0
            var buffer: [Int: FileOutcome] = [:]
            var tickScheduled = false
            var stopped = false

            func schedule() {
                while !stopped, next < paths.count, inFlight < limits.workers, next - emit < limits.reorderWindow {
                    let i = next, path = paths[i]
                    next += 1
                    inFlight += 1
                    group.addTask {
                        .file(await Self.scanFile(index: i, path: path, matcher: matcher, regex: regex, root: root,
                                                  overlay: overlays[path], limits: limits, gate: gate, large: large))
                    }
                }
                if !tickScheduled, !pending.isEmpty {
                    tickScheduled = true
                    group.addTask {
                        try? await Task.sleep(for: limits.flushInterval)
                        return .tick
                    }
                }
            }

            func drain() {
                while !stopped, let o = buffer.removeValue(forKey: emit) {
                    emit += 1
                    if o.skipped { facts.skipped += 1 }
                    if o.sawOnlyEmpty { anyEmpty = true }
                    guard !o.matches.isEmpty else { continue }
                    if facts.totalFiles >= limits.maxFiles {
                        facts.cappedFiles = true; stopped = true; break
                    }
                    var matches = o.matches
                    let room = maxResults - facts.totalMatches
                    if matches.count > room {
                        matches = Array(matches.prefix(max(0, room)))
                        facts.cappedMatches = true; stopped = true
                    }
                    if !matches.isEmpty {
                        facts.totalMatches += matches.count
                        facts.totalFiles += 1
                        pending.append(SearchFileResult(index: o.index, path: o.path, matches: matches, isUTF8: o.isUTF8))
                        pendingMatches += matches.count
                    }
                    if !stopped, facts.totalMatches >= maxResults { facts.cappedMatches = true; stopped = true }
                    if pendingMatches >= limits.flushMatches { flush() }
                }
            }

            schedule()
            while let event = await group.next() {
                if Task.isCancelled { group.cancelAll(); return }
                switch event {
                case .file(let o):
                    inFlight -= 1
                    buffer[o.index] = o
                    drain()
                case .tick:
                    tickScheduled = false
                    flush()
                }
                if stopped || (inFlight == 0 && next >= paths.count) { group.cancelAll(); break }
                schedule()
            }
        }
        if Task.isCancelled { return }
        facts.onlyEmptyMatches = facts.totalMatches == 0 && anyEmpty
        continuation.yield(SearchBatch(files: pending, finished: facts))
    }

    // MARK: One file

    private static func scanFile(index: Int, path: String, matcher: SearchMatcher, regex: Bool, root: URL,
                                 overlay: CodeSnapshot?, limits: SearchLimits,
                                 gate: (@Sendable (String) async -> Void)?, large: AsyncSemaphore) async -> FileOutcome {
        var out = FileOutcome(index: index, path: path)
        if Task.isCancelled { return out }
        if let gate { await gate(path) }
        if Task.isCancelled { return out }

        let bytes: [UInt8]
        if let overlay {
            bytes = overlay.utf8(in: 0..<overlay.utf8Count)
        } else {
            let url = root.appendingPathComponent(path)
            guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
                  let size = (attrs[.size] as? NSNumber)?.intValue else { out.skipped = true; return out }
            if size > limits.maxFileBytes { out.skipped = true; return out }
            let isLarge = size > limits.largeFileBytes
            if isLarge { await large.acquire() }
            defer { if isLarge { Task { await large.release() } } }
            if Task.isCancelled { return out }
            guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { out.skipped = true; return out }
            if data.count > limits.maxFileBytes { out.skipped = true; return out }
            if data.prefix(limits.binaryProbe).contains(0) { out.skipped = true; return out }
            bytes = [UInt8](data)
        }

        let result = matcher.scan(bytes, regexBudget: regex ? limits.regexBudget : nil, shouldStop: { Task.isCancelled })
        out.matches = result.matches
        out.sawOnlyEmpty = result.sawOnlyEmpty
        if result.skippedLongLines || result.overBudget { out.skipped = true }
        if !out.matches.isEmpty, overlay == nil {
            out.isUTF8 = String(bytes: bytes, encoding: .utf8) != nil
        }
        return out
    }
}

/// A one-slot async lock for files too big to read in parallel.
private actor AsyncSemaphore {
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func acquire() async {
        if !busy { busy = true; return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func release() {
        if waiters.isEmpty { busy = false } else { waiters.removeFirst().resume() }
    }
}
