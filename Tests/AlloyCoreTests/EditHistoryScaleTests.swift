import Foundation
import Testing
@testable import AlloyCore

private struct ScaleRng: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// A plain per-character model of the fragment sequence: one entry per scalar, no splitting, no caches.
private struct ReferenceHistory {
    struct Ch { var scalar: Unicode.Scalar; var inserter: UUID?; var deleters: Set<UUID> = [] }
    var chars: [Ch]
    var states: [UUID: EditRecord.State] = [:]
    var seqs: [UUID: Int] = [:]

    init(baseline: String) { chars = baseline.unicodeScalars.map { Ch(scalar: $0, inserter: nil) } }

    func visible(_ c: Ch) -> Bool {
        if let e = c.inserter, states[e] == .reverted { return false }
        return !c.deleters.contains { states[$0] != .reverted }
    }
    var text: String { String(String.UnicodeScalarView(chars.filter(visible).map(\.scalar))) }

    mutating func register(_ e: UUID) { states[e] = .live; seqs[e] = seqs.count }

    mutating func apply(_ ops: [TextOp], as e: UUID) {
        for op in ops.reversed() {
            let vis = chars.indices.filter { visible(chars[$0]) }
            for k in 0..<op.deleteCount { chars[vis[op.start + k]].deleters.insert(e) }
            if !op.insert.isEmpty {
                let at = op.start == 0 ? 0 : vis[op.start - 1] + 1
                chars.insert(contentsOf: op.insert.unicodeScalars.map { Ch(scalar: $0, inserter: e) }, at: at)
            }
        }
    }

    func lineOwners() -> [UUID?] {
        var out: [UUID?] = []
        var atStart = true
        for c in chars where visible(c) {
            if atStart { out.append(nil); atStart = false }
            if let e = c.inserter, states[e] == .live {
                let cur = out[out.count - 1].flatMap { seqs[$0] } ?? -1
                if seqs[e]! > cur { out[out.count - 1] = e }
            }
            if c.scalar == "\n" { atStart = true }
        }
        return out
    }
}

@Suite struct EditHistoryScaleTests {
    /// A few thousand single-character edits (typing, deleting, mid-text) against the plain model.
    @Test func thousandsOfSingleCharacterEditsMatchReference() {
        var rng = ScaleRng(state: 7)
        let baseline = (0..<40).map { "line \($0)\n" }.joined()
        var history = EditHistory(baseline: baseline)
        var ref = ReferenceHistory(baseline: baseline)
        var length = baseline.unicodeScalars.count
        let alphabet = Array("abc\nxyz é")
        for i in 0..<3_000 {
            let e = UUID()
            history.register(e); ref.register(e)
            let op: TextOp
            if length > 0, Int.random(in: 0..<4, using: &rng) == 0 {
                op = TextOp(start: Int.random(in: 0..<length, using: &rng), deleteCount: 1, insert: "")
                length -= 1
            } else {
                let ch = alphabet[i % alphabet.count]
                op = TextOp(start: Int.random(in: 0...length, using: &rng), deleteCount: 0, insert: String(ch))
                length += 1
            }
            history.apply([op], as: e); ref.apply([op], as: e)
        }
        #expect(history.visibleText == ref.text)
        #expect(history.visibleLength == length)
        #expect(history.lineOwners() == ref.lineOwners())
        #expect(history.runs().map(\.text).joined() == ref.text)
    }

    /// ASCII fragments split by byte offset; a cut between "\r" and "\n" must not round to a grapheme boundary.
    @Test func splitBetweenCarriageReturnAndLineFeed() {
        var history = EditHistory(baseline: "a\r\nb\r\n")
        let e = UUID()
        history.register(e)
        history.apply([TextOp(start: 2, deleteCount: 0, insert: "X")], as: e)
        #expect(history.visibleText == "a\rX\nb\r\n")
        #expect(history.fragments.map(\.length).reduce(0, +) == 7)
    }

    /// Seeded random multi-op edits with reverts and keeps, compared after every step.
    @Test func randomEditsRevertsAndKeepsMatchReference() {
        let alphabet = Array("ab\ncd é\n")
        for seed in 0..<60 {
            var rng = ScaleRng(state: UInt64(seed) &+ 100)
            let baseline = String((0..<Int.random(in: 0...12, using: &rng)).map { _ in alphabet.randomElement(using: &rng)! })
            var history = EditHistory(baseline: baseline)
            var ref = ReferenceHistory(baseline: baseline)
            var edits: [UUID] = []
            for _ in 0..<40 {
                switch Int.random(in: 0..<8, using: &rng) {
                case 0 where !edits.isEmpty:
                    let e = edits.randomElement(using: &rng)!
                    if ref.states[e] == .live { history.setState(e, .reverted); ref.states[e] = .reverted }
                case 1 where !edits.isEmpty:
                    let e = edits.randomElement(using: &rng)!
                    if ref.states[e] == .live { history.keep(e); ref.states[e] = .kept }
                default:
                    let e = UUID()
                    history.register(e); ref.register(e)
                    edits.append(e)
                    var length = ref.text.unicodeScalars.count
                    var ops: [TextOp] = []
                    var cursor = 0
                    for _ in 0..<Int.random(in: 1...3, using: &rng) where cursor <= length {
                        let start = Int.random(in: cursor...length, using: &rng)
                        let del = Int.random(in: 0...min(3, length - start), using: &rng)
                        let ins = String((0..<Int.random(in: 0...3, using: &rng)).map { _ in alphabet.randomElement(using: &rng)! })
                        if del == 0, ins.isEmpty { continue }
                        ops.append(TextOp(start: start, deleteCount: del, insert: ins))
                        cursor = start + del + 1
                        length = max(length, cursor)
                    }
                    // Offsets are in pre-edit text; drop ops that run past it.
                    let pre = ref.text.unicodeScalars.count
                    ops = ops.filter { $0.start + $0.deleteCount <= pre }
                    history.apply(ops, as: e); ref.apply(ops, as: e)
                }
                #expect(history.visibleText == ref.text)
                #expect(history.lineOwners() == ref.lineOwners())
            }
            // Visibility is derived state: a decoded copy recomputes it.
            if let data = try? JSONEncoder().encode(history), let back = try? JSONDecoder().decode(EditHistory.self, from: data) {
                #expect(back == history)
                #expect(back.visibleText == ref.text)
                #expect(back.lineOwners() == ref.lineOwners())
            } else {
                Issue.record("EditHistory did not round-trip")
            }
        }
    }
}
