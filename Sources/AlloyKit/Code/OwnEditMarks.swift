import AlloyCore
import Foundation
import MetalUI
import MetalUICodeBuffer
import Observation

extension Color {
    /// The colour of the user's own-edit tint: the picked `#RRGGBB[AA]` when it parses, else the theme's "you" colour.
    static func ownEditTint(_ settings: AlloySettings) -> Color {
        if let hex = settings.ownEditTint.colorHex, let rgba = ThemeRGBA(hex: hex) { return Color(rgba.hsla) }
        return .userAuthor
    }
}

/// What one open view tints for the user's own unsaved edits: the buffer against the document's saved text, kept as the
/// `own` decoration owner. Off by default; with the setting off nothing here runs. An edit restarts a 0.3 s pause on the
/// workspace clock, then the diff runs off the main thread. A save, a toggle off and a presentation that is not plain or
/// inline clear the tint at once. MetalUI carries the decorations through typing between recomputes.
@MainActor
final class OwnEditMarks {
    /// Priority 1: an unsaved edit shows over an agent's bar on the same line.
    static let owner = CodeDecorationOwner("own", priority: 1)
    static let pause = 0.3

    private(set) weak var view: OpenDocumentView?
    private weak var workspace: Workspace?
    private var generation = 0
    private var timer: Task<Void, Never>?
    private var showing = false
    private var lastMode: Presentation?
    private var lastTint: OwnEditTint
    private var observing = true

    /// Observability for tests.
    private(set) var recomputeCount = 0
    private(set) var lastDiffOffMain: Bool?
    /// A test hook awaited inside the detached diff.
    var diffGate: (@Sendable () async -> Void)?
    var isShowing: Bool { showing }

    init(view: OpenDocumentView, workspace: Workspace) {
        self.view = view
        self.workspace = workspace
        self.lastTint = workspace.settings.ownEditTint
        observeSettings()
    }

    private var enabled: Bool { workspace?.settings.ownEditTint.enabled ?? false }

    // MARK: Triggers

    /// The view's presentation was seen; a change recomputes (plain and inline show the tint, the others clear it).
    func presentationSeen(_ mode: Presentation) {
        guard mode != lastMode else { return }
        lastMode = mode
        if enabled || showing { recompute() }
    }

    /// The buffer was edited: restart the pause timer. Does nothing with the setting off.
    func typed() {
        guard enabled, let clock = workspace?.scheduleClock else { return }
        timer?.cancel()
        let deadline = clock.now + Self.pause
        timer = Task { @MainActor [weak self] in
            do { try await clock.sleep(until: deadline) } catch { return }
            guard !Task.isCancelled else { return }
            self?.recompute()
        }
    }

    /// The document was saved or refreshed from disk: a clean buffer clears at once, a dirty one diffs again.
    func savedChanged() {
        guard let view else { return }
        if !view.document.isDirty { clear() } else if enabled { recompute() }
    }

    func teardown() {
        observing = false
        clear()
    }

    /// Removes the tint and stops any pending work.
    func clear() {
        generation += 1
        timer?.cancel(); timer = nil
        if let view, showing { view.decorations.removeDecorations(of: Self.owner) }
        showing = false
    }

    /// Recomputes the tint from the buffer as it is now.
    func recompute() {
        guard let view, !view.closed else { return }
        generation += 1
        let gen = generation
        timer?.cancel(); timer = nil
        let mode = view.currentPresentation
        guard enabled, mode == .plain || mode == .inline else { clearKeepingGeneration(); return }
        let document = view.document
        let saved = document.savedSnapshot
        let snapshot = document.buffer.snapshot()
        guard snapshot.utf8Count <= GitGutterMarks.sizeLimit, saved.utf8Count <= GitGutterMarks.sizeLimit else {
            clearKeepingGeneration(); return
        }
        guard document.isDirty else { clearKeepingGeneration(); return }
        recomputeCount += 1
        let gate = diffGate
        Task { [weak self] in
            let (lines, offMain) = await Task.detached { () -> ([Range<Int>], Bool) in
                await gate?()
                return Self.diff(saved: saved, current: snapshot)
            }.value
            self?.finish(gen, lines, snapshot, offMain)
        }
    }

    /// The changed lines, and whether they were found off the main thread. Never called on the main actor.
    nonisolated static func diff(saved: CodeSnapshot, current: CodeSnapshot) -> ([Range<Int>], Bool) {
        let offMain = !Thread.isMainThread
        return (OwnEdits.changedLines(saved: saved.text, current: current.text), offMain)
    }

    private func clearKeepingGeneration() {
        if let view, showing { view.decorations.removeDecorations(of: Self.owner) }
        showing = false
    }

    private func finish(_ gen: Int, _ lines: [Range<Int>], _ snapshot: CodeSnapshot, _ offMain: Bool) {
        guard gen == generation, let view, !view.closed, let workspace else { return }
        lastDiffOffMain = offMain
        guard enabled else { clearKeepingGeneration(); return }
        let color = Color.ownEditTint(workspace.settings)
        let last = max(0, snapshot.lineCount - 1)
        var decorations: [CodeLineDecoration] = []
        for range in lines {
            // A deletion-only region marks the line the text was joined onto.
            let clipped = range.isEmpty ? min(range.lowerBound, last)..<(min(range.lowerBound, last) + 1)
                                        : min(range.lowerBound, last)..<min(range.upperBound, snapshot.lineCount)
            guard !clipped.isEmpty, snapshot.lineCount > 0 else { continue }
            decorations.append(CodeLineDecoration(lines: clipped, gutterBar: color, background: .addedRowTint))
        }
        if decorations.isEmpty { clearKeepingGeneration(); return }
        view.decorations.setLineDecorations(decorations, asOf: snapshot.version, owner: Self.owner)
        showing = true
    }

    // MARK: Settings

    /// Watches the setting; a change of the toggle or the colour redraws (or, off, clears) at once. Armed only by a
    /// change, so it costs nothing while idle.
    private func observeSettings() {
        guard observing, let workspace else { return }
        withObservationTracking {
            _ = workspace.settings.ownEditTint
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self, self.observing else { return }
                self.settingsChanged()
                self.observeSettings()
            }
        }
    }

    private func settingsChanged() {
        guard let workspace, workspace.settings.ownEditTint != lastTint else { return }
        lastTint = workspace.settings.ownEditTint
        if lastTint.enabled { recompute() } else { clear() }
    }
}
