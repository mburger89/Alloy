import AlloyCore
import Foundation
import Observation

/// The per-session UI state that must outlive a session switch. `ChatColumn` gets a fresh identity for every selected
/// session, which frees its `@State`; anything kept there (the composer draft, an encode still running whose deferred
/// send waits on it, unsent card picks, collapse overrides) would vanish. The store is owned above the column, by
/// `AlloyScreen`, and hands every session its same ``Entry`` back.
@MainActor
final class SessionUIStore {
    /// The glass bars' last measured heights. A new column or panel seeds its inset from these (else the style's estimate), so its first
    /// frame already clears the bar. Per window: the store is owned by `AlloyScreen`.
    @MainActor final class BarMetrics {
        var composerBarHeight: Double?
        var filePanelBarHeight: Double?
    }
    let metrics = BarMetrics()

    @MainActor @Observable
    final class Entry {
        /// The composer itself: draft, attachments, pending encodes and deferred sends.
        @ObservationIgnored let composer: ComposerModel
        /// Unsent question picks and plan feedback by request id.
        var drafts: [String: CardDraft] = [:]
        /// Collapse the user toggled, by block id.
        var overrides: [String: Bool] = [:]
        /// Code blocks the user expanded past six lines, by `<blockID>-<part>`.
        var codeExpanded: [String: Bool] = [:]
        /// A block id the transcript should scroll to (set by "Show in chat" in the code panel, cleared once scrolled).
        var scrollTarget: String?
        /// Code-block lines and colours by `<blockID>-<part>`.
        @ObservationIgnored let codeBlocks = CodeBlockStore()
        /// Parsed Markdown by block id.
        @ObservationIgnored let markdownCache = MarkdownCache()

        /// The window's bar heights, shared by every session's column.
        @ObservationIgnored let metrics: BarMetrics

        init(composer: ComposerModel, metrics: BarMetrics) { self.composer = composer; self.metrics = metrics }
    }

    private var entries: [Session.ID: Entry] = [:]

    func entry(for session: Session, workspace: Workspace) -> Entry {
        if let existing = entries[session.id] { return existing }
        let made = Entry(composer: ComposerModel(workspace: workspace, sessionID: session.id), metrics: metrics)
        entries[session.id] = made
        return made
    }

    /// Drops a session's state, for when sessions can be deleted. Nothing calls it yet: `Workspace` has no session
    /// deletion path. Wire it in when one exists. (Code-block items of vanished blocks are pruned by `TranscriptView`.)
    func forget(_ id: Session.ID) { entries.removeValue(forKey: id) }
}
