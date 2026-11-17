import Foundation

/// Why an edit to a file that is not open could not be written.
public struct EditApplyError: Error, LocalizedError, Sendable {
    public var message: String
    public var errorDescription: String? { message }
}

extension Workspace {
    /// Applies `edits` (ascending, non-overlapping byte ranges of the file's current text) to the file at project-relative
    /// `path`, which is not open in an editor. The file is read and written off the main actor, only if its stamp is still
    /// `expectedStamp`; the write keeps its POSIX mode. The change is then recorded in the ledger as the user's, in
    /// `group`, so the file watcher does not attribute it to someone else. Throws a described error when the file changed,
    /// cannot be read or written, or an edit does not fit its text.
    public func applyToClosedFile(_ path: String, edits: [(range: Range<Int>, text: String)], expectedStamp: FileStamp,
                                  group: UUID?) async throws {
        let target = projectRoot.appendingPathComponent(path).standardizedFileURL.resolvingSymlinksInPath()
        let changed = EditApplyError(message: "\(path) changed on disk")
        let (old, new) = try await Task.detached { () -> (String, String) in
            guard FileStamp.read(target.path) == expectedStamp else { throw changed }
            var bytes = [UInt8](try Data(contentsOf: target))
            let original = String(decoding: bytes, as: UTF8.self)
            // Highest first, so every range is still in the coordinates of the original; equal starts apply last
            // to first, which leaves them in array order.
            for edit in edits.reversed() {
                guard edit.range.lowerBound >= 0, edit.range.upperBound <= bytes.count else {
                    throw EditApplyError(message: "An edit does not fit \(path)")
                }
                bytes.replaceSubrange(edit.range, with: Array(edit.text.utf8))
            }
            let aborted = try Workspace.writeKeepingMode(Data(bytes), to: target,
                                                         abortIf: { FileStamp.read(target.path) != expectedStamp })
            if aborted { throw changed }
            return (original, String(decoding: bytes, as: UTF8.self))
        }.value
        await appendToLedger(path, saved: nil, baseline: old, edits: [(.user, new)], group: group)
    }
}
