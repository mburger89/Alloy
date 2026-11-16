import AlloyHighlight
import Foundation
import MetalUI
import MetalUICodeBuffer

/// Colours a document that has no tree-sitter grammar with the semantic tokens of its language server. It installs no
/// highlight provider (nothing is asked per frame): requests are made on open and 150 ms after the last edit, and a
/// finished answer is applied once with `setHighlights(..., layer: .semantic, asOf:)`. Decoding happened off the main
/// actor; this class only styles and applies the runs.
@MainActor
final class SemanticHighlighter {
    /// Quiet time after the last edit before tokens are requested again.
    static let debounce: Duration = .milliseconds(150)

    /// A decorations the colours go to, with the style ids this highlighter registered in it.
    private final class Target {
        weak var decorations: CodeDecorations?
        var styleIDs: [SyntaxToken: CodeStyleID] = [:]
        init(_ decorations: CodeDecorations) { self.decorations = decorations }
    }

    private var targets: [Target] = []
    private let path: String
    private let request: @MainActor (String) -> Void
    private let palette: SyntaxPalette
    private var debounceTask: Task<Void, Never>?
    private var stopped = false
    /// The last answer, replayed to a decorations attached later.
    private var last: (runs: [(Range<Int>, SyntaxToken)], version: Int)?

    /// The style ids of the first attached decorations (test observability).
    var styleIDs: [SyntaxToken: CodeStyleID] { targets.first { $0.decorations != nil }?.styleIDs ?? [:] }

    /// How many answers were applied, and the buffer version of the last (test observability).
    private(set) var appliedCount = 0
    private(set) var lastAppliedVersion: Int?
    /// Runs in the last application (test observability).
    private(set) var appliedRunCount = 0
    /// Requests made so far (test observability).
    private(set) var requestCount = 0

    /// Made once the server is known to offer tokens; the first answer to the panel's probing request is already on its way.
    /// - Parameter request: asks the language server for `path`'s tokens.
    init(path: String, decorations: CodeDecorations? = nil, palette: SyntaxPalette = SyntaxPalette(),
         request: @escaping @MainActor (String) -> Void) {
        self.path = path
        self.palette = palette
        self.request = request
        if let decorations { attach(decorations) }
    }

    /// Colours `decorations` too, replaying the last answer to it.
    func attach(_ decorations: CodeDecorations) {
        targets.removeAll { $0.decorations == nil }
        guard !stopped, !targets.contains(where: { $0.decorations === decorations }) else { return }
        let target = Target(decorations)
        targets.append(target)
        if let last { write(last.runs, version: last.version, to: target) }
    }

    /// Stops colouring `decorations` and removes its colours.
    func detach(_ decorations: CodeDecorations) {
        guard let index = targets.firstIndex(where: { $0.decorations === decorations }) else { return }
        targets.remove(at: index)
        decorations.setHighlights([], in: 0..<(1 << 40), layer: .semantic, asOf: decorations.buffer.version)
    }

    /// The document changed: the next request waits for 150 ms without another change, and any earlier wait is dropped.
    func documentChanged() {
        guard !stopped else { return }
        debounceTask?.cancel()
        debounceTask = Task { [weak self] in
            try? await Task.sleep(for: Self.debounce)
            guard !Task.isCancelled else { return }
            self?.send()
        }
    }

    private func send() {
        guard !stopped else { return }
        requestCount += 1
        request(path)
    }

    /// Applies the runs the server's tokens gave for buffer version `version`; MetalUI carries them through later edits.
    /// Answers the edit log no longer reaches are dropped, and the tokens asked for again.
    func apply(_ runs: [(Range<Int>, SyntaxToken)], version: Int) {
        targets.removeAll { $0.decorations == nil }
        guard !stopped else { return }
        guard let first = targets.first?.decorations else { last = (runs, version); return }
        guard first.buffer.map(0, from: UInt64(version), bias: .after) != nil else { send(); return }
        last = (runs, version)
        var count = 0
        for target in targets { count = write(runs, version: version, to: target) }
        appliedRunCount = count
        appliedCount += 1
        lastAppliedVersion = version
    }

    /// Styles and sets `runs` in one target; returns the number of runs set.
    @discardableResult
    private func write(_ runs: [(Range<Int>, SyntaxToken)], version: Int, to target: Target) -> Int {
        guard let decorations = target.decorations else { return 0 }
        let asOf = UInt64(version)
        guard decorations.buffer.map(0, from: asOf, bias: .after) != nil else { return 0 }
        let styled = runs.compactMap { run -> CodeStyleRun? in
            // Plain variables keep the text colour, so they need no run.
            run.1 == .variable || run.1 == .plain ? nil : CodeStyleRun(range: run.0, style: styleID(for: run.1, in: target))
        }
        decorations.setHighlights(styled, in: 0..<(1 << 40), layer: .semantic, asOf: asOf)
        return styled.count
    }

    /// Stops requesting and removes the colours.
    func stop() {
        guard !stopped else { return }
        stopped = true
        debounceTask?.cancel()
        debounceTask = nil
        last = nil
        for target in targets {
            if let decorations = target.decorations {
                decorations.setHighlights([], in: 0..<(1 << 40), layer: .semantic, asOf: decorations.buffer.version)
            }
        }
        targets = []
    }

    private func styleID(for token: SyntaxToken, in target: Target) -> CodeStyleID {
        if let id = target.styleIDs[token] { return id }
        let id = target.decorations!.register(palette.dynamicStyle(token))
        target.styleIDs[token] = id
        return id
    }
}
