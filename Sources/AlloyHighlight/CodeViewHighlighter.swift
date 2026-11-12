import Foundation
import MetalUI

/// Answers a `CodeView`'s highlight requests from a `HighlightEngine`. `CodeDecorations` holds its provider
/// weakly, so the owner must retain this object.
///
/// At most one request is in flight; rows asked for meanwhile are merged into one pending request. Every
/// request bumps a generation: a result older than the latest request is dropped (the pending one is sent
/// instead). The engine answers a request only once its text has reached the snapshot's version (the owner
/// feeds `engine.edit` asynchronously), and a result is applied only if the engine's version equals the
/// snapshot's; a stale one is asked again on the buffer's newest snapshot, if the buffer has moved on.
@MainActor
public final class CodeViewHighlighter: CodeHighlightProvider {
    private struct Request {
        var rows: Range<Int>
        var snapshot: CodeSnapshot
    }

    private let engine: HighlightEngine
    private let documentID: UUID
    private weak var decorations: CodeDecorations?
    private let palette: SyntaxPalette
    private var styleIDs: [SyntaxToken: CodeStyleID] = [:]
    private var inFlight = false
    private var pending: Request?
    private var generation = 0

    /// Versions highlights were applied as of, in order (test observability).
    private(set) var appliedVersions: [UInt64] = []
    /// The byte range most recently asked of the engine (test observability).
    private(set) var lastRequestedBytes: Range<Int>?
    /// Results dropped because a newer request existed.
    private(set) var supersededCount = 0
    /// Results dropped because the engine's text version differed from the snapshot's.
    private(set) var staleCount = 0
    /// No request is in flight or waiting.
    var isIdle: Bool { !inFlight && pending == nil }

    public init(engine: HighlightEngine, documentID: UUID, decorations: CodeDecorations, palette: SyntaxPalette = SyntaxPalette()) {
        self.engine = engine
        self.documentID = documentID
        self.decorations = decorations
        self.palette = palette
        decorations.highlightProvider = self
    }

    public func decorations(_ decorations: CodeDecorations, needHighlightsForRows rows: Range<Int>, in snapshot: CodeSnapshot) {
        generation += 1
        if inFlight {
            // The newer request supersedes: its snapshot, the rows of both.
            let merged = pending.map { min($0.rows.lowerBound, rows.lowerBound)..<max($0.rows.upperBound, rows.upperBound) } ?? rows
            pending = Request(rows: merged, snapshot: snapshot)
            return
        }
        start(Request(rows: rows, snapshot: snapshot))
    }

    private func start(_ request: Request) {
        let first = max(0, request.rows.lowerBound), last = min(request.snapshot.lineCount, request.rows.upperBound)
        guard first < last else { return }
        // Cover every requested row through its newline: `lineRange` excludes it, and MetalUI probes a blank row
        // through that byte, so leaving it out keeps the row "missing" and re-requested on every frame.
        let snapshot = request.snapshot
        let lower = snapshot.lineRange(first).lowerBound
        let upper = last < snapshot.lineCount ? snapshot.lineRange(last).lowerBound : snapshot.utf8Count
        lastRequestedBytes = lower..<upper
        inFlight = true
        let mine = generation
        Task { [engine, documentID] in
            let answer = await engine.captures(id: documentID, byteRange: lower..<upper, minVersion: request.snapshot.version)
            self.finish(answer, range: lower..<upper, request: request, generation: mine)
        }
    }

    private func finish(_ answer: (version: UInt64, runs: [(Range<Int>, SyntaxToken)]), range: Range<Int>,
                        request: Request, generation mine: Int) {
        inFlight = false
        if mine != generation, let next = pending {
            supersededCount += 1
            pending = nil
            start(next)
            return
        }
        guard let decorations else { return }
        guard answer.version == request.snapshot.version else {
            staleCount += 1
            // The buffer moved on while the answer was made: ask again on its newest snapshot. This cannot spin,
            // because each re-ask needs a newer buffer version than the last. (An answer that is stale with the
            // buffer unchanged, a timed-out wait or a closed document, waits for the next buffer change.)
            let newest = decorations.buffer.snapshot()
            if newest.version > request.snapshot.version { start(Request(rows: request.rows, snapshot: newest)) }
            return
        }
        let runs = answer.runs.map { CodeStyleRun(range: $0.0, style: styleID(for: $0.1, in: decorations)) }
        decorations.setHighlights(runs, in: range, layer: .syntax, asOf: answer.version)
        appliedVersions.append(answer.version)
    }

    private func styleID(for token: SyntaxToken, in decorations: CodeDecorations) -> CodeStyleID {
        if let id = styleIDs[token] { return id }
        let id = decorations.register(palette.dynamicStyle(token))
        styleIDs[token] = id
        return id
    }
}
