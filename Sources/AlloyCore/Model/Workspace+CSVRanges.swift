import Foundation
import MetalUICodeBuffer

/// Row-level (and later cell-level) Keep and Revert for CSV files, on byte ranges.
extension Workspace {
    /// Keeps the pieces of the ledger the targets stand for: the rest of each edit stays live and tinted. Changes the
    /// ledger only, never the buffer. False (nothing changed) for read-only documents or targets computed against an
    /// older ledger.
    @discardableResult
    public func keepRanges(path: String, targets: [CSVRangeTarget]) -> Bool {
        ensureLoaded()
        guard let doc = documents[path], doc.state == .editable, var file = ledger.files[path],
              !targets.isEmpty, targets.allSatisfy({ $0.ledgerVersion == file.version }) else { return false }
        let text = file.currentText
        func scalars(_ byte: Int) -> Int {
            let u = text.utf8
            guard let i = u.index(u.startIndex, offsetBy: min(byte, u.count), limitedBy: u.endIndex) else { return text.unicodeScalars.count }
            return text.unicodeScalars.distance(from: text.unicodeScalars.startIndex, to: i)
        }
        var changed = false
        for t in targets {
            for p in t.keeps where file.keep(p.edit, visibleRange: scalars(p.range.lowerBound)..<scalars(p.range.upperBound)) != nil {
                changed = true
                revertConflicts[p.edit] = nil
            }
        }
        guard changed else { return false }
        ledger.files[path] = file
        reindex(path)
        persistLedger()
        return true
    }

    /// Restores the previous bytes of each target in ONE `.programmatic` transaction, bottom to top; a deletion
    /// marker re-inserts its removed rows. The ledger records the change at the next save. Refuses silently on
    /// read-only documents, and with a notice when the file changed since the targets were computed.
    @discardableResult
    public func revertRanges(path: String, targets: [CSVRangeTarget], in pane: PaneID) -> Bool {
        guard let doc = documents[path], doc.state == .editable, !targets.isEmpty else { return false }
        guard targets.allSatisfy({ $0.bufferVersion == doc.buffer.version }) else {
            notify(path: path, kind: .warning, text: "This row changed while you were reverting it.")
            return false
        }
        let count = doc.buffer.snapshot().utf8Count
        let ordered = targets.sorted { $0.current.lowerBound > $1.current.lowerBound }
        guard ordered.allSatisfy({ $0.current.upperBound <= count }) else { return false }
        let tail = count > 0 ? doc.buffer.snapshot().utf8(in: (count - 1)..<count) : []
        let nl = Self.lineEnding(in: doc.buffer.snapshot())
        _ = doc.buffer.transaction { buffer in
            for t in ordered {
                if let at = t.insertAt {
                    var text = t.removedRows.map { $0 + nl }.joined()
                    if at == count, count > 0, tail.last != 0x0A { text = nl + t.removedRows.joined(separator: nl) }
                    _ = buffer.replace(at..<at, with: text, origin: .programmatic)
                } else {
                    _ = buffer.replace(t.current, with: t.replacement ?? "", origin: .programmatic)
                }
            }
        }
        return true
    }

    private static func lineEnding(in snapshot: CodeSnapshot) -> String {
        let n = min(snapshot.utf8Count, 4096)
        let bytes = snapshot.utf8(in: 0..<n)
        guard let i = bytes.firstIndex(of: 0x0A) else { return "\n" }
        return i > 0 && bytes[i - 1] == 0x0D ? "\r\n" : "\n"
    }
}
