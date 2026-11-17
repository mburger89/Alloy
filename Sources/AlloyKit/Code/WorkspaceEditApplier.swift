import AlloyCore
import AlloyLSP
import Foundation
import MetalUICodeBuffer

/// Applies the edits language servers produce (a format, later a rename) to the workspace: open documents through the
/// editor's own undo history, closed files on disk, and one ledger group for all of them. Everything is checked before
/// anything is written, so a stale edit changes nothing.
@MainActor
final class WorkspaceEditApplier {
    struct ApplyOutcome: Equatable {
        var applied: [String]
        var failed: [String: String]
        var message: String?
        var group: UUID
    }

    private let workspace: Workspace
    private let coordinator: LSPCoordinator?
    /// Runs between validation and the first write. Tests use it to change a file in that window.
    var afterValidation: (@MainActor () async -> Void)?

    init(workspace: Workspace, coordinator: LSPCoordinator?) {
        self.workspace = workspace
        self.coordinator = coordinator
    }

    private enum Target {
        case open(EditorDocument, bufferVersion: UInt64)
        case closed(stamp: FileStamp)
    }

    /// `saveOpenFiles` false leaves an edited open document dirty (an explicit format is one undo step, not a save; a
    /// format on save is followed by the save that called it).
    /// `baseVersions` holds the buffer version each open file's edits were computed for, for edits that name no version.
    func apply(_ files: [FileEdits], baseVersions: [String: UInt64], label: String,
               saveOpenFiles: Bool = true) async -> ApplyOutcome {
        let group = UUID()
        let stale = ApplyOutcome(applied: [], failed: [:], message: "File changed, \(label) not applied", group: group)
        var targets: [Target] = []
        for file in files {
            if let doc = workspace.document(file.path) {
                guard doc.state == .editable else {
                    return ApplyOutcome(applied: [], failed: [:], message: "\(file.path) is read-only, \(label) not applied", group: group)
                }
                let bufferVersion = doc.buffer.version
                if let version = file.version {
                    let synced = if let coordinator { await coordinator.syncedVersion(path: file.path) } else { Int(bufferVersion) }
                    guard version == synced, UInt64(max(0, version)) == bufferVersion else { return stale }
                } else {
                    guard baseVersions[file.path] == bufferVersion else { return stale }
                }
                guard doc.buffer.version == bufferVersion, Self.fits(file.edits, in: doc.buffer.snapshot().utf8Count) else { return stale }
                targets.append(.open(doc, bufferVersion: bufferVersion))
            } else {
                guard let stamp = FileStamp.read(workspace.projectRoot.appendingPathComponent(file.path).path) else { return stale }
                targets.append(.closed(stamp: stamp))
            }
        }
        await afterValidation?()
        // Nothing has been written yet: look once more, without suspending, so nothing moved since the checks.
        for (file, target) in zip(files, targets) {
            switch target {
            case .open(let doc, let bufferVersion):
                guard workspace.document(file.path) === doc, doc.buffer.version == bufferVersion else { return stale }
            case .closed(let stamp):
                guard workspace.document(file.path) == nil,
                      FileStamp.read(workspace.projectRoot.appendingPathComponent(file.path).path) == stamp else { return stale }
            }
        }

        var applied: [String] = []
        var failed: [String: String] = [:]
        for (file, target) in zip(files, targets) {
            do {
                switch target {
                case .open(let doc, _):
                    let edits = file.edits.reversed()   // highest first; equal starts keep the server's order
                    let body: (CodeBuffer) -> Void = { buffer in
                        for edit in edits { buffer.replace(edit.range, with: edit.text, origin: .programmatic) }
                    }
                    if let state = workspace.selectionState(for: file.path, in: workspace.defaultPane) {
                        state.transaction(body)
                    } else {
                        doc.buffer.transaction(body)
                    }
                    if saveOpenFiles { try await workspace.save(file.path, group: group) }
                case .closed(let stamp):
                    try await workspace.applyToClosedFile(file.path, edits: file.edits.map { ($0.range, $0.text) },
                                                          expectedStamp: stamp, group: group)
                }
                applied.append(file.path)
            } catch {
                failed[file.path] = error.localizedDescription
            }
        }
        var message: String?
        if !failed.isEmpty {
            let reasons = failed.sorted { $0.key < $1.key }.map { "\($0.key): \($0.value)" }.joined(separator: "; ")
            message = "\(label) applied to \(applied.count) of \(files.count) files; \(failed.count) failed: \(reasons)"
        }
        return ApplyOutcome(applied: applied, failed: failed, message: message, group: group)
    }

    private static func fits(_ edits: [ByteEdit], in count: Int) -> Bool {
        edits.allSatisfy { $0.range.lowerBound >= 0 && $0.range.upperBound <= count }
    }
}
