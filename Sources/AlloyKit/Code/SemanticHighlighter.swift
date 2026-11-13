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

    private weak var decorations: CodeDecorations?
    private let path: String
    private let request: @MainActor (String) -> Void
    private let palette: SyntaxPalette
    private(set) var styleIDs: [SyntaxToken: CodeStyleID] = [:]
    private var debounceTask: Task<Void, Never>?
    private var stopped = false

    /// How many answers were applied, and the buffer version of the last (test observability).
    private(set) var appliedCount = 0
    private(set) var lastAppliedVersion: Int?
    /// Runs in the last application (test observability).
    private(set) var appliedRunCount = 0
    /// Requests made so far (test observability).
    private(set) var requestCount = 0

    /// Made once the server is known to offer tokens; the first answer to the panel's probing request is already on its way.
    /// - Parameter request: asks the language server for `path`'s tokens.
    init(path: String, decorations: CodeDecorations, palette: SyntaxPalette = SyntaxPalette(),
         request: @escaping @MainActor (String) -> Void) {
        self.path = path
        self.decorations = decorations
        self.palette = palette
        self.request = request
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
        guard !stopped, let decorations else { return }
        let asOf = UInt64(version)
        guard decorations.buffer.map(0, from: asOf, bias: .after) != nil else { send(); return }
        let styled = runs.compactMap { run -> CodeStyleRun? in
            // Plain variables keep the text colour, so they need no run.
            run.1 == .variable || run.1 == .plain ? nil : CodeStyleRun(range: run.0, style: styleID(for: run.1, in: decorations))
        }
        decorations.setHighlights(styled, in: 0..<(1 << 40), layer: .semantic, asOf: asOf)
        appliedRunCount = styled.count
        appliedCount += 1
        lastAppliedVersion = version
    }

    /// Stops requesting and removes the colours.
    func stop() {
        guard !stopped else { return }
        stopped = true
        debounceTask?.cancel()
        debounceTask = nil
        if let decorations {
            decorations.setHighlights([], in: 0..<(1 << 40), layer: .semantic, asOf: decorations.buffer.version)
        }
    }

    private func styleID(for token: SyntaxToken, in decorations: CodeDecorations) -> CodeStyleID {
        if let id = styleIDs[token] { return id }
        let id = decorations.register(palette.dynamicStyle(token))
        styleIDs[token] = id
        return id
    }
}
