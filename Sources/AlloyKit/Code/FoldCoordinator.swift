import AlloyCore
import AlloyHighlight
import AlloyLSP
import Foundation
import MetalUICodeBuffer
import Observation

/// Computes the fold ranges of every open document and hands them to the workspace's fold states.
///
/// One source per document, never merged: language server over tree-sitter over indentation. Builds run on the
/// version settle (a debounce after the last edit, or at once on open and save), off the main actor, at most one in
/// flight per document, and are applied only if the buffer did not move meanwhile. A keystroke only splices the
/// indentation cache and records the time: it allocates no task and starts no build.
@MainActor @Observable
final class FoldCoordinator {
    struct FoldRanges: Equatable {
        var version: UInt64
        var source: FoldSource
        var ranges: [FoldRange]
    }

    struct Sources {
        /// The language server's folding ranges of a snapshot.
        var lsp: @Sendable (String, CodeSnapshot) async -> FoldingOutcome
        /// The tree-sitter ranges of the document for a buffer version (nil: none, or for another version).
        var tree: @Sendable (UUID, UInt64) async -> (version: UInt64, ranges: [FoldRange])?
    }

    /// Per document: the incremental indentation cache and the settle and build tasks.
    private final class Entry {
        let document: EditorDocument
        weak var services: DocumentServices?
        var indent: IndentFolds
        var generation = 0
        var lastEdit = 0.0
        var timer: Task<Void, Never>?
        var build: Task<Void, Never>?
        var token = 0
        var inFlight = false
        var builds = 0
        init(document: EditorDocument, services: DocumentServices?, indent: IndentFolds) {
            self.document = document; self.services = services; self.indent = indent
        }
    }

    private(set) var ranges: [String: FoldRanges] = [:]

    @ObservationIgnored private let sources: Sources
    @ObservationIgnored private let debounce: Double
    @ObservationIgnored private let lspTimeout: Duration
    /// Documents over this many bytes are windowed in the highlight engine: never asked for tree-sitter ranges.
    @ObservationIgnored private let windowedBytes: Int
    @ObservationIgnored private weak var workspace: Workspace?
    @ObservationIgnored private var entries: [String: Entry] = [:]

    init(sources: Sources, debounce: Duration = .milliseconds(300), lspTimeout: Duration = .seconds(1),
         windowedBytes: Int = 1_048_576) {
        self.sources = sources
        self.debounce = Double(debounce.components.seconds) + Double(debounce.components.attoseconds) / 1e18
        self.lspTimeout = lspTimeout
        self.windowedBytes = windowedBytes
    }

    func attach(workspace: Workspace) { self.workspace = workspace }

    /// Test observability: builds started for the document's current entry, and whether one is running.
    func buildCount(path: String) -> Int { entries[path]?.builds ?? 0 }
    func inFlight(path: String) -> Bool { entries[path]?.inFlight ?? false }

    // MARK: Document life

    /// The document is ready (the engine holds its text, or it has no grammar): starts its entry and builds at once. A
    /// second call for a path (a replaced document) starts afresh.
    func opened(_ services: DocumentServices) {
        let document = services.document
        retire(document.path)
        ranges.removeValue(forKey: document.path)
        services.drainEdits()
        let entry = Entry(document: document, services: services, indent: IndentFolds(snapshot: document.buffer.snapshot()))
        entries[document.path] = entry
        build(path: document.path)
    }

    /// The buffer changed by `edits`: splices the indentation cache and waits for the settle.
    func edited(path: String, edits: [CodeEdit]) {
        guard let entry = entries[path] else { return }
        entry.indent.apply(edits)
        touch(entry, path: path)
    }

    /// The buffer changed in a way that has no edit list: the cache starts over.
    func resynced(path: String, snapshot: CodeSnapshot) {
        guard let entry = entries[path] else { return }
        entry.indent.reset(to: snapshot)
        touch(entry, path: path)
    }

    /// A build now: after a save and after a language-server settings reload.
    func settled(path: String) {
        guard entries[path] != nil else { return }
        build(path: path)
    }

    func closed(path: String) {
        retire(path)
        ranges.removeValue(forKey: path)
    }

    private func retire(_ path: String) {
        guard let entry = entries.removeValue(forKey: path) else { return }
        entry.timer?.cancel()
        entry.build?.cancel()
        entry.token += 1
        entry.inFlight = false
    }

    // MARK: Settle

    private func touch(_ entry: Entry, path: String) {
        entry.generation += 1
        guard let clock = workspace?.scheduleClock else { return }
        entry.lastEdit = clock.now
        if entry.inFlight { entry.build?.cancel(); entry.inFlight = false }
        if entry.timer != nil { return }
        let wait = debounce
        entry.timer = Task { [weak self, weak entry] in
            // One task sleeps through a burst: on waking it sleeps on if a later edit moved the deadline.
            while let self, let entry, !Task.isCancelled {
                let deadline = entry.lastEdit + wait
                do { try await clock.sleep(until: deadline) } catch { return }
                if Task.isCancelled { return }
                if clock.now >= entry.lastEdit + wait { break }
            }
            guard let self, let entry, !Task.isCancelled else { return }
            entry.timer = nil
            if self.entries[path] === entry { self.build(path: path) }
        }
    }

    // MARK: Build

    private func build(path: String) {
        guard let entry = entries[path] else { return }
        entry.timer?.cancel()
        entry.timer = nil
        entry.build?.cancel()
        entry.services?.drainEdits()
        entry.token += 1
        entry.builds += 1
        entry.inFlight = true
        let token = entry.token
        let snapshot = entry.document.buffer.snapshot()
        let version = snapshot.version
        let generation = entry.generation
        let id = entry.document.id
        let firstLine = snapshot.lineCount > 0 ? snapshot.line(0) : nil
        let hasGrammar = AlloyHighlight.Language.detect(path: path, firstLine: firstLine) != nil
        let wantsTree = hasGrammar && snapshot.utf8Count <= windowedBytes
        let sources = self.sources, timeout = lspTimeout
        // The copy lives for the whole build, so the first keystroke during a slow language-server wait pays one
        // copy-on-write of the line cache. Bounded: once per build.
        let indentCopy = entry.indent
        entry.build = Task { [weak self, weak entry] in
            let work = Task.detached { () -> (IndentFolds, [FoldRange]) in
                var indent = indentCopy
                let found = indent.ranges(in: snapshot)
                return (indent, found)
            }
            async let treeAnswer = wantsTree ? await sources.tree(id, version) : nil
            let (measured, indentation) = await withTaskCancellationHandler { await work.value } onCancel: { work.cancel() }
            let tree = await treeAnswer
            guard !Task.isCancelled, let self, let entry, self.current(entry, path: path, token: token, version: version) else { return }
            if generation == entry.generation { entry.indent = measured }
            let lineCount = snapshot.lineCount
            let treeRanges = tree.flatMap { $0.version == version ? FoldMerge.normalized($0.ranges, lineCount: lineCount) : nil }
            if self.ranges[path]?.source != .lsp {
                let choice = FoldMerge.choose(lsp: nil, treeSitter: treeRanges, indentation: indentation)
                self.publish(path: path, choice: choice, version: version)
            }
            // Stage two: the language server, raced against its timeout.
            let outcome = await Self.race(timeout: timeout) { await sources.lsp(path, snapshot) }
            guard !Task.isCancelled, self.current(entry, path: path, token: token, version: version) else { return }
            if case .answered(let answer) = outcome {
                let normalized = FoldMerge.normalized(answer, lineCount: lineCount)
                if !normalized.isEmpty { self.publish(path: path, choice: FoldChoice(source: .lsp, ranges: normalized), version: version) }
            }
            entry.inFlight = false
        }
    }

    /// Whether the build `token` of `entry` is still the live one for the buffer at `version`.
    private func current(_ entry: Entry, path: String, token: Int, version: UInt64) -> Bool {
        entries[path] === entry && entry.token == token && entry.document.buffer.version == version
            && workspace?.document(path) === entry.document
    }

    private func publish(path: String, choice: FoldChoice, version: UInt64) {
        ranges[path] = FoldRanges(version: version, source: choice.source, ranges: choice.ranges)
        workspace?.applyFoldRanges(path: path, choice: choice, version: version)
    }

    /// `work`'s answer, or `.unavailable` when `timeout` passes first or the calling task is cancelled. Neither a slow
    /// nor a cancelled `work` that ignores cancellation holds the caller up.
    private static func race(timeout: Duration, _ work: @escaping @Sendable () async -> FoldingOutcome) async -> FoldingOutcome {
        let gate = Gate()
        let job = Task { gate.finish(await work()) }
        let timer = Task {
            try? await Task.sleep(for: timeout)
            gate.finish(.unavailable)
        }
        defer { job.cancel(); timer.cancel() }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<FoldingOutcome, Never>) in
                gate.wait(continuation)
            }
        } onCancel: {
            job.cancel()
            timer.cancel()
            gate.finish(.unavailable)
        }
    }

    /// Delivers the first outcome to the one waiter.
    private final class Gate: @unchecked Sendable {
        private let lock = NSLock()
        private var outcome: FoldingOutcome?
        private var waiter: CheckedContinuation<FoldingOutcome, Never>?

        func finish(_ value: FoldingOutcome) {
            let toResume: CheckedContinuation<FoldingOutcome, Never>? = lock.withLock {
                guard outcome == nil else { return nil }
                outcome = value
                defer { waiter = nil }
                return waiter
            }
            toResume?.resume(returning: value)
        }

        func wait(_ continuation: CheckedContinuation<FoldingOutcome, Never>) {
            let ready: FoldingOutcome? = lock.withLock {
                if let outcome { return outcome }
                waiter = continuation
                return nil
            }
            if let ready { continuation.resume(returning: ready) }
        }
    }
}

extension FoldCoordinator.Sources {
    /// The sources of a running app: the highlight engine's fold query and the language-server coordinator.
    @MainActor
    static func production(engine: HighlightEngine, lsp: @escaping @MainActor () -> LSPCoordinator?) -> Self {
        .init(
            lsp: { path, snapshot in
                guard let coordinator = await lsp() else { return .unavailable }
                return await coordinator.foldingRanges(path: path, snapshot: snapshot)
            },
            tree: { id, version in await engine.foldRanges(documentID: id, minVersion: version) })
    }
}
