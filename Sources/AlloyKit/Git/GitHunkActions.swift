import AlloyCore
import Foundation
import MetalUI
import MetalUICodeBuffer

/// What a revert did.
enum GitRevertOutcome: Equatable {
    case reverted
    /// The hunk shares rows with an unreviewed Claude edit; nothing changed. Ask, then call again with `confirmed`.
    case needsConfirmation
    /// The hunk is gone or changed since the click (typing, a save, a new HEAD); nothing changed.
    case stale
}

extension GitDocumentMarks {
    // MARK: Fresh hunks

    /// The hunk of the buffer as it is now that is `hunk` (same old and new lines at the same old position), computed
    /// off the main actor against `base`. Nil when it is gone. The snapshot it was found in is returned with it.
    private func fresh(_ hunk: GitHunk, base: String, snapshot: CodeSnapshot) async -> GitHunk? {
        let found = await Task.detached { GitHunks.compute(base: base, buffer: snapshot.text) }.value
        return found.first { $0.oldStart == hunk.oldStart && $0.oldCount == hunk.oldCount && $0.oldLines == hunk.oldLines && $0.newLines == hunk.newLines }
    }

    // MARK: Revert

    /// Reverts `hunk`: puts HEAD's lines back as one undoable edit of the buffer (the save then reaches the ledger as
    /// the user's). A hunk that shares rows with a pending Claude edit asks first (`needsConfirmation`).
    func revert(_ hunk: GitHunk, confirmed: Bool) async -> GitRevertOutcome {
        guard let base = baseText else { return .stale }
        return await revert(parts: [hunk], base: base, confirmed: confirmed)
    }

    /// Reverts several zero-context changes against `base` (HEAD's or the index's text) as one undoable edit. The
    /// confirmation covers all of them: nothing changes unless every one is still there.
    func revert(parts: [GitHunk], base: String, confirmed: Bool) async -> GitRevertOutcome {
        guard let view, !view.closed, view.document.state == .editable, !parts.isEmpty else { return .stale }
        let snapshot = view.document.buffer.snapshot()
        let found = await Task.detached { GitHunks.compute(base: base, buffer: snapshot.text) }.value
        var currents: [GitHunk] = []
        for part in parts {
            guard let match = found.first(where: { $0.oldStart == part.oldStart && $0.oldCount == part.oldCount && $0.oldLines == part.oldLines && $0.newLines == part.newLines }) else { return .stale }
            currents.append(match)
        }
        guard !view.closed, view.document.buffer.version == snapshot.version else { return .stale }
        if !confirmed, currents.contains(where: { overlapsPendingClaudeEdit($0, snapshot: snapshot) }) { return .needsConfirmation }
        let buffer = view.document.buffer
        let edits = currents.map { Self.reversion(of: $0, base: base, snapshot: snapshot, ending: buffer.lineEnding.text) }
            .sorted { $0.0.lowerBound < $1.0.lowerBound }
        // One replacement over the span of all of them, so a single undo restores the buffer.
        let low = edits[0].0.lowerBound, high = edits.map(\.0.upperBound).max() ?? low
        var bytes: [UInt8] = []
        var cursor = low
        for (range, text) in edits {
            if range.lowerBound > cursor { bytes += snapshot.utf8(in: cursor..<range.lowerBound) }
            bytes += Array(text.utf8)
            cursor = max(cursor, range.upperBound)
        }
        if cursor < high { bytes += snapshot.utf8(in: cursor..<high) }
        buffer.breakUndoCoalescing()
        buffer.replace(low..<high, with: String(decoding: bytes, as: UTF8.self), origin: .programmatic)
        buffer.breakUndoCoalescing()
        return .reverted
    }

    /// The bytes of `snapshot` to replace and what replaces them to restore `hunk`'s old lines.
    static func reversion(of hunk: GitHunk, base: String, snapshot: CodeSnapshot, ending: String) -> (Range<Int>, String) {
        func start(_ row: Int) -> Int { row >= snapshot.lineCount ? snapshot.utf8Count : snapshot.lineRange(row).lowerBound }
        let first = hunk.newCount == 0 ? hunk.newStart : hunk.newStart - 1
        let range = start(first)..<start(first + hunk.newCount)
        let base = TextLines(base)
        let oldEndsAtEOF = hunk.oldCount > 0 && hunk.oldStart + hunk.oldCount - 1 >= base.lines.count
        var text = ""
        for (i, line) in hunk.oldLines.enumerated() {
            text += line
            let isLast = i == hunk.oldLines.count - 1
            if !(isLast && oldEndsAtEOF && !base.hasTrailingNewline) { text += ending }
        }
        return (range, text)
    }

    /// Whether `hunk`'s rows (a deletion's: the row after the wedge) share a row with an unreviewed edit by a session,
    /// both in the current buffer. Unsure counts as shared.
    private func overlapsPendingClaudeEdit(_ hunk: GitHunk, snapshot: CodeSnapshot) -> Bool {
        guard let view, let workspace = coordinator?.host, let file = workspace.ledger.files[path] else { return false }
        func isSession(_ author: Author) -> Bool { if case .session = author { true } else { false } }
        let live = file.edits.filter { $0.state == .live && isSession($0.author) }
        guard !live.isEmpty else { return false }
        view.services.drainEdits()
        let saved = view.document.savedSnapshot
        // A session edit may have reached the ledger before the buffer: the rows cannot be compared.
        guard saved.utf8(in: 0..<saved.utf8Count) == Array(file.text.text.utf8) else { return true }
        let authors = Dictionary(file.edits.map { ($0.id, $0.author) }, uniquingKeysWith: { a, _ in a })
        let entries = file.diffEntries()
        let model = DiffDecorationModel.build(entries.map(\.line), terminators: entries.map(\.terminator),
                                              authorOf: { authors[$0] ?? .outside }, lineEnding: view.document.buffer.lineEnding.text)
        let lines = model.lineBars.filter { isSession($0.author) }.map { CodeLineDecoration(lines: $0.rows) }
        let gaps = model.removedGroups.filter { isSession($0.author) }.map { CodeVirtualRow(anchor: .before(line: $0.beforeRow), lines: [""]) }
        guard let moved = view.services.rowLog.move(lines: lines, rows: gaps, from: view.document.savedVersion,
                                                    rowCount: saved.lineCount, to: view.document.buffer.version) else { return true }
        let rows = hunk.newCount == 0 ? hunk.newStart..<(hunk.newStart + 1) : hunk.bufferRows
        if moved.lines.contains(where: { $0.lines.overlaps(rows) }) { return true }
        return moved.rows.contains { row in
            if case .before(let line) = row.anchor { return rows.contains(line) }
            return false
        }
    }

    // MARK: Stage and unstage

    /// Stages `hunk` as the buffer has it now (an unsaved buffer included): the index text against the buffer.
    func stage(_ hunk: GitHunk) async -> GitCommandResult { await stage(parts: [hunk], headBase: baseText) }

    /// Stages each zero-context change (against HEAD's text, or, with `headBase` nil, already against the index).
    func stage(parts: [GitHunk], headBase: String?) async -> GitCommandResult {
        var last = Self.failure(Self.alreadyStaged)
        for part in parts {
            let result = await stageOne(part, headBase: headBase)
            if !result.ok && result.stderr == Self.alreadyStaged { continue }   // a part the index already has
            if !result.ok { return result }
            last = result
        }
        return last
    }

    private static let alreadyStaged = "This change is already staged."
    private static let notStaged = "This change is not staged."


    private func stageOne(_ hunk: GitHunk, headBase: String?) async -> GitCommandResult {
        guard let view, let coordinator else { return Self.failure("This file has no changes to stage.") }
        let snapshot = view.document.buffer.snapshot()
        let clicked: GitHunk
        if let headBase {
            guard let match = await fresh(hunk, base: headBase, snapshot: snapshot) else { return Self.failure("This change moved. Try again.") }
            clicked = match
        } else {
            clicked = hunk
        }
        let service = coordinator.service
        await service.refreshNow()   // the index may have changed since the last status
        guard let oid = await service.indexBlobOID(path: path), let index = await service.indexText(oid: oid) else {
            return Self.failure("The index copy of this file could not be read.")
        }
        let found = await Task.detached { GitHunks.compute(base: index, buffer: snapshot.text) }.value
        guard let target = found.first(where: { $0.newStart == clicked.newStart && $0.newLines == clicked.newLines }) else {
            return Self.failure(Self.alreadyStaged)
        }
        let ending = index.contains("\r\n") ? "\r\n" : "\n"
        let result = await service.stageHunk(path: path, hunk: target, lineEnding: ending,
                                             noNewlineAtEnd: Self.noNewline(target, old: index, new: snapshot.text))
        await service.refreshNow()
        return result
    }

    /// Unstages the staged form of `hunk`: HEAD's text against the index's.
    func unstage(_ hunk: GitHunk) async -> GitCommandResult { await unstage(parts: [hunk], headBase: baseText) }

    /// Unstages each zero-context change (against HEAD's text).
    func unstage(parts: [GitHunk], headBase: String?) async -> GitCommandResult {
        guard let headBase else { return Self.failure("This file has no changes to unstage.") }
        var last = Self.failure(Self.notStaged)
        for part in parts {
            let result = await unstageOne(part, headBase: headBase)
            if !result.ok && result.stderr == Self.notStaged { continue }
            if !result.ok { return result }
            last = result
        }
        return last
    }

    private func unstageOne(_ hunk: GitHunk, headBase: String) async -> GitCommandResult {
        guard let view, let coordinator else { return Self.failure("This file has no changes to unstage.") }
        let snapshot = view.document.buffer.snapshot()
        guard let clicked = await fresh(hunk, base: headBase, snapshot: snapshot) else { return Self.failure("This change moved. Try again.") }
        let service = coordinator.service
        await service.refreshNow()   // the index may have changed since the last status
        guard let oid = await service.indexBlobOID(path: path), let index = await service.indexText(oid: oid) else {
            return Self.failure("The index copy of this file could not be read.")
        }
        let found = await Task.detached { GitHunks.compute(base: headBase, buffer: index) }.value
        guard let target = found.first(where: { $0.oldStart == clicked.oldStart && $0.oldLines == clicked.oldLines && $0.newLines == clicked.newLines }) else {
            return Self.failure(Self.notStaged)
        }
        let ending = index.contains("\r\n") ? "\r\n" : "\n"
        let result = await service.unstageHunk(path: path, hunk: target, lineEnding: ending,
                                               noNewlineAtEnd: Self.noNewline(target, old: headBase, new: index))
        await service.refreshNow()
        return result
    }

    private static func failure(_ message: String) -> GitCommandResult { GitCommandResult(ok: false, stderr: message) }

    /// Whether the hunk's last old / new line is the last line of its text and that text has no final newline.
    private static func noNewline(_ hunk: GitHunk, old: String, new: String) -> (old: Bool, new: Bool) {
        let a = TextLines(old), b = TextLines(new)
        return (hunk.oldCount > 0 && hunk.oldStart + hunk.oldCount - 1 >= a.lines.count && !a.hasTrailingNewline && !a.lines.isEmpty,
                hunk.newCount > 0 && hunk.newStart + hunk.newCount - 1 >= b.lines.count && !b.hasTrailingNewline && !b.lines.isEmpty)
    }
}
