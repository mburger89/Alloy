import Foundation
import MetalUICodeBuffer
import Observation

public enum DocState: Equatable, Sendable {
    case editable
    case readOnly(reason: String)
}

public enum DiffMode: Sendable { case inline, sideBySide }

/// One open file: a `CodeBuffer` plus what ties it to disk and the ledger. `language` is the lowercased file
/// extension (nil when none): AlloyCore stays UI-free, so AlloyKit maps it to a highlighter language.
@MainActor @Observable
public final class EditorDocument: Identifiable {
    public let id = UUID()
    public let path: String
    public let buffer: CodeBuffer
    public let language: String?
    public internal(set) var state: DocState
    /// The buffer version when the buffer equalled disk and ledger.
    public var savedVersion: UInt64
    public var diskStamp: FileStamp
    /// The text at `savedVersion`, which is what the file held when Alloy last read or wrote it (a rope, so
    /// cheap to keep). `DirtyMerge` diffs a session's change against it.
    @ObservationIgnored public private(set) var savedSnapshot: CodeSnapshot
    /// Reads the buffer's edit stream from the last save on, so a merge can tell what the user changed.
    @ObservationIgnored private var editCursor: CodeEditCursor
    /// Events drained from `editCursor` that are newer than `savedVersion`.
    @ObservationIgnored private var editLog: [CodeEdit] = []
    @ObservationIgnored var editLogLost = false
    /// Set when a merge could not be followed by a successful save: the next merge keeps all user text.
    @ObservationIgnored var mergeUnreliable = false
    /// The disk text last merged into the buffer since the last save.
    @ObservationIgnored var lastMergedBytes: [UInt8]?
    public var diffMode: DiffMode = .inline

    public var isDirty: Bool { buffer.version != savedVersion }

    /// `isDirty` as a stored value that changes only when the document goes clean to dirty or back, so the tab
    /// strip (which reads this, not `isDirty`) does not re-render on every keystroke. It trails typing by a task
    /// hop, and `markSaved` updates it at once. Refresh it with `refreshTabDirty()` after a buffer change.
    public private(set) var tabDirty = false

    func refreshTabDirty() {
        let dirty = isDirty
        if tabDirty != dirty { tabDirty = dirty }
    }

    public init(path: String, buffer: CodeBuffer, language: String?, state: DocState, diskStamp: FileStamp) {
        self.path = path; self.buffer = buffer; self.language = language
        self.state = state; self.diskStamp = diskStamp
        self.savedVersion = buffer.version
        self.savedSnapshot = buffer.snapshot()
        self.editCursor = buffer.makeEditCursor()
    }

    /// Records that the file now holds `snapshot`'s text (after a save, or a refresh from disk).
    func markSaved(snapshot: CodeSnapshot, stamp: FileStamp) {
        savedVersion = snapshot.version
        refreshTabDirty()
        savedSnapshot = snapshot
        diskStamp = stamp
        mergeUnreliable = false
        lastMergedBytes = nil
        editLog.removeAll { $0.version <= snapshot.version }
        // Typing during a save leaves the cursor where it was: it still reaches back past `savedVersion`.
        if buffer.version == snapshot.version {
            editCursor = buffer.makeEditCursor()
            editLog = []
            editLogLost = false
        }
    }

    /// Every edit to the buffer since `savedVersion`, oldest first, or nil when the log no longer reaches back.
    func editsSinceSave() -> [CodeEdit]? {
        switch editCursor.drain() {
        case .edits(let events): editLog.append(contentsOf: events.filter { $0.version > savedVersion })
        case .resync: editLogLost = true
        }
        return editLogLost ? nil : editLog
    }
}
