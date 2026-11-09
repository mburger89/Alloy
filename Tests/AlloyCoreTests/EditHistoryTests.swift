import Foundation
import Testing
@testable import AlloyCore

private struct Rng: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

@Suite struct EditHistoryTests {
    /// Random full-text edits (line and character level) against a plain String model.
    @Test func randomEditSequencesMatchPlainText() {
        let alphabet = Array("ab c\nd\n")
        for seed in 0..<300 {
            var rng = Rng(state: UInt64(seed) &+ 1)
            var plain = (0..<Int.random(in: 0...6, using: &rng)).map { _ in String(alphabet.randomElement(using: &rng)!) }.joined()
            var l = FileLedger(path: "f", baseline: plain)
            let authors: [Author] = [.session(UUID()), .session(UUID()), .user]
            for step in 0..<Int.random(in: 1...20, using: &rng) {
                var chars = Array(plain)
                let n = Int.random(in: 1...3, using: &rng)
                for _ in 0..<n {
                    let at = Int.random(in: 0...chars.count, using: &rng)
                    switch Int.random(in: 0..<3, using: &rng) {
                    case 0:
                        let ins = (0..<Int.random(in: 1...4, using: &rng)).map { _ in alphabet.randomElement(using: &rng)! }
                        chars.insert(contentsOf: ins, at: at)
                    case 1 where !chars.isEmpty:
                        let from = min(at, chars.count - 1)
                        chars.removeSubrange(from..<min(chars.count, from + Int.random(in: 1...4, using: &rng)))
                    default:
                        if !chars.isEmpty { chars[min(at, chars.count - 1)] = alphabet.randomElement(using: &rng)! }
                    }
                }
                plain = String(chars)
                _ = l.applyFullText(author: authors[step % 3], newText: plain, toolUseID: nil, date: Date(timeIntervalSince1970: Double(step)))
                #expect(l.text.text == plain, "seed \(seed) step \(step)")
                #expect(l.lineOwners().count == l.text.lines.count)
                if l.text.text != plain { return }
            }
            // Keeping everything must not change the text.
            l.keepAll { _ in true }
            #expect(l.text.text == plain)
        }
    }

    /// Reverting edit k equals replaying every other edit's hunks on the baseline, when that replays cleanly.
    @Test func revertThenTextMatchesWithoutThatEdit() {
        var compared = 0, conflicts = 0
        for seed in 0..<200 {
            var rng = Rng(state: UInt64(seed) &+ 7_777)
            var counter = 0
            func fresh() -> String { counter += 1; return "L\(counter)" }
            var lines = (0..<Int.random(in: 3...8, using: &rng)).map { _ in fresh() }
            let baseLines = lines
            var l = FileLedger(path: "f", baseline: lines.joined(separator: "\n") + "\n")
            var ids: [UUID] = []
            for step in 0..<Int.random(in: 1...6, using: &rng) {
                let at = Int.random(in: 0...lines.count, using: &rng)
                switch Int.random(in: 0..<3, using: &rng) {
                case 0: lines.insert(contentsOf: (0..<Int.random(in: 1...3, using: &rng)).map { _ in fresh() }, at: at)
                case 1 where lines.count > 1:
                    let i = min(at, lines.count - 1)
                    lines.removeSubrange(i..<min(lines.count, i + Int.random(in: 1...2, using: &rng)))
                default: if !lines.isEmpty { lines[min(at, lines.count - 1)] = fresh() }
                }
                let new = lines.joined(separator: "\n") + "\n"
                if let r = l.applyFullText(author: .session(UUID()), newText: new, toolUseID: nil, date: Date(timeIntervalSince1970: Double(step))) {
                    ids.append(r.id)
                }
            }
            for k in ids.indices {
                var copy = l
                let outcome = copy.revert(ids[k], date: Date())
                guard case .reverted(let text) = outcome else { conflicts += 1; continue }
                #expect(copy.text.text == text)
                var replay = baseLines
                var clean = true
                for (j, id) in ids.enumerated() where j != k {
                    let rec = l.edits.first { $0.id == id }!
                    guard let out = try? Patch.apply(rec.hunks, to: replay) else { clean = false; break }
                    replay = out
                }
                if clean {
                    compared += 1
                    #expect(text == (replay.isEmpty ? "" : replay.joined(separator: "\n") + "\n"), "seed \(seed) k \(k)")
                }
            }
        }
        #expect(compared > 100, "too few comparable cases: \(compared) (conflicts \(conflicts))")
    }

    @Test func fragmentsStayContiguousAndCountedInScalars() {
        var l = FileLedger(path: "f", baseline: "héllo 👍\n")
        _ = l.applyFullText(author: .user, newText: "héllo 👍👍 x\n", toolUseID: nil, date: Date())
        #expect(l.text.text == "héllo 👍👍 x\n")
        #expect(l.offset(of: l.anchor(atOffset: 7, bias: .right)) == 7)
    }

    /// Mixed edits, reverts and keeps; invariants hold after every step.
    @Test func randomEditsRevertsKeepsStayConsistent() {
        var successfulReverts = 0
        let alphabet = Array("ab c\nd\n")
        for seed in 0..<200 {
            var rng = Rng(state: UInt64(seed) &+ 424_242)
            var plain = String((0..<Int.random(in: 0...8, using: &rng)).map { _ in alphabet.randomElement(using: &rng)! })
            var l = FileLedger(path: "f", baseline: plain)
            var anchors: [Anchor] = []
            let authors: [Author] = [.session(UUID()), .session(UUID()), .user]
            func check(_ what: String) {
                let t = l.text.text
                #expect(l.runs().map(\.text).joined() == t, "runs \(what) seed \(seed)")
                let n = t.unicodeScalars.count
                for a in anchors { #expect((0...n).contains(l.offset(of: a)), "anchor \(what) seed \(seed)") }
                #expect(l.lineOwners().count == l.text.lines.count, "owners \(what) seed \(seed)")
            }
            for step in 0..<Int.random(in: 5...25, using: &rng) {
                let live = l.edits.filter { $0.state == .live }
                switch Int.random(in: 0..<5, using: &rng) {
                case 0 where !live.isEmpty:
                    let before = l
                    let id = live.randomElement(using: &rng)!.id
                    switch l.revert(id, date: Date(timeIntervalSince1970: Double(step))) {
                    case .conflict: #expect(l == before, "conflict mutated, seed \(seed)")
                    case .reverted(let t): successfulReverts += 1; #expect(l.text.text == t)
                    }
                    plain = l.text.text
                case 1 where !live.isEmpty:
                    let before = l.text.text
                    l.keep(live.randomElement(using: &rng)!.id)
                    #expect(l.text.text == before, "keep changed text, seed \(seed)")
                default:
                    var chars = Array(plain)
                    let at = Int.random(in: 0...chars.count, using: &rng)
                    if Bool.random(using: &rng) || chars.isEmpty {
                        chars.insert(contentsOf: (0..<Int.random(in: 1...4, using: &rng)).map { _ in alphabet.randomElement(using: &rng)! }, at: at)
                    } else {
                        let from = min(at, chars.count - 1)
                        chars.removeSubrange(from..<min(chars.count, from + Int.random(in: 1...3, using: &rng)))
                    }
                    plain = String(chars)
                    l.applyFullText(author: authors[step % 3], newText: plain, toolUseID: nil, date: Date(timeIntervalSince1970: Double(step)))
                    #expect(l.text.text == plain, "text seed \(seed) step \(step)")
                }
                let n = l.text.text.unicodeScalars.count
                anchors.append(l.anchor(atOffset: Int.random(in: 0...n, using: &rng), bias: Bool.random(using: &rng) ? .left : .right))
                check("step \(step)")
            }
        }
        #expect(successfulReverts > 0, "every revert conflicted")
    }

    /// Every changed line in diffLines is attributed to an edit that actually touched that line.
    /// The oracle is a plain model of lines (every character unique, so text identifies a line); it records
    /// per line which edits touched it: token edits, character deletions (also at line start), whole-line
    /// inserts, splits (touch both resulting lines) and joins (touch the joined line), empty lines, LF and CRLF.
    @Test func diffLineAttributionNeverNamesUnrelatedEdit() {
        struct ModelLine { var text: String; var origs: Set<String>; var touchers: Set<UUID> }
        var checked = 0, splits = 0, joins = 0, deletions = 0
        for seed in 0..<2000 {
            var rng = Rng(state: UInt64(seed) &+ 99_001)
            var counter = 0
            func chars(_ n: Int) -> String {
                String((0..<n).map { _ in counter += 1; return Character(UnicodeScalar(0x4E00 + counter)!) })
            }
            let trailing = Bool.random(using: &rng)
            let eol = Bool.random(using: &rng) ? "\n" : "\r\n"
            var model = (0..<Int.random(in: 1...5, using: &rng)).map { _ -> ModelLine in
                let t = Int.random(in: 0..<5, using: &rng) == 0 ? "" : chars(Int.random(in: 1...4, using: &rng))
                return ModelLine(text: t, origs: [t], touchers: [])
            }
            // Whether a blank line placed at `index` (or, replacing, already there) touches another blank line.
            func blankNeighbour(_ m: [ModelLine], between index: Int, replacing: Bool = false) -> Bool {
                let before = index - 1, after = replacing ? index + 1 : index
                return (before >= 0 && m[before].text.isEmpty) || (after < m.count && m[after].text.isEmpty)
            }
            func render(_ m: [ModelLine]) -> String { m.map(\.text).joined(separator: eol) + (trailing ? eol : "") }
            // An unterminated final empty line cannot be told apart from a terminated file.
            func valid(_ m: [ModelLine]) -> Bool { trailing || m.last?.text.isEmpty == false }
            if !valid(model) { model[model.count - 1].text = chars(1); model[model.count - 1].origs = [model[model.count - 1].text] }
            var l = FileLedger(path: "f", baseline: render(model))
            var log: [String] = [render(model).debugDescription]
            for step in 0..<Int.random(in: 1...7, using: &rng) {
                var next = model
                var touched: [Int] = []
                var kind = ""
                switch Int.random(in: 0..<6, using: &rng) {
                case 0:
                    let i = Int.random(in: 0..<next.count, using: &rng); kind = "token"
                    // Writing into one of several adjacent blank lines: a full-text diff cannot tell which
                    // blank line was written, so the edit is not well defined.
                    if next[i].text.isEmpty, (i > 0 && next[i - 1].text.isEmpty) || (i + 1 < next.count && next[i + 1].text.isEmpty) { continue }
                    let tok = chars(2)
                    next[i].text = Bool.random(using: &rng) ? tok + next[i].text : next[i].text + tok
                    touched = [i]
                case 1:
                    let i = Int.random(in: 0...next.count, using: &rng); kind = "insert"
                    let t = Int.random(in: 0..<4, using: &rng) == 0 ? "" : chars(Int.random(in: 1...3, using: &rng))
                    if t.isEmpty, blankNeighbour(next, between: i) { continue }
                    next.insert(ModelLine(text: t, origs: [], touchers: []), at: i)
                    touched = [i]
                    // Appending after an unterminated final line gives that line a terminator.
                    if !trailing, i == next.count - 1, i > 0 { touched.append(i - 1) }
                case 2, 3:
                    let i = Int.random(in: 0..<next.count, using: &rng); kind = "split"
                    let chs = Array(next[i].text)
                    let p = Int.random(in: 0...chs.count, using: &rng)
                    if p == 0 || p == chs.count {
                        // A split at either end only adds an empty line; which of the neighbouring
                        // terminators is "the new one" is not observable, so it is an empty-line insert.
                        let at = p == 0 ? i : i + 1
                        if blankNeighbour(next, between: at) { continue }
                        next.insert(ModelLine(text: "", origs: [], touchers: []), at: at)
                        touched = [at]
                    } else {
                        var a = next[i], b = next[i]
                        a.text = String(chs[..<p]); b.text = String(chs[p...])
                        next.replaceSubrange(i...i, with: [a, b])
                        touched = [i, i + 1]
                    }
                case 4:
                    guard next.count > 1 else { continue }
                    let i = Int.random(in: 0..<(next.count - 1), using: &rng); kind = "join"
                    if next[i].text.isEmpty, next[i + 1].text.isEmpty { continue }   // which blank vanished is not observable
                    var a = next[i]; let b = next[i + 1]
                    a.text += b.text; a.origs.formUnion(b.origs); a.touchers.formUnion(b.touchers)
                    next.replaceSubrange(i...(i + 1), with: [a])
                    touched = [i]
                default:
                    let candidates = next.indices.filter { !next[$0].text.isEmpty }
                    guard let i = candidates.randomElement(using: &rng) else { continue }
                    kind = "delete"
                    var chs = Array(next[i].text)
                    chs.remove(at: Bool.random(using: &rng) ? 0 : Int.random(in: 0..<chs.count, using: &rng))
                    next[i].text = String(chs)
                    if chs.isEmpty, blankNeighbour(next, between: i, replacing: true) { continue }
                    touched = [i]
                }
                guard valid(next),
                      let rec = l.applyFullText(author: .session(UUID()), newText: render(next), toolUseID: nil,
                                                date: Date(timeIntervalSince1970: Double(step))) else { continue }
                for t in touched { next[t].touchers.insert(rec.id) }
                model = next
                switch kind { case "split": splits += 1; case "join": joins += 1; case "delete": deletions += 1; default: break }
                log.append("\(kind) " + rec.id.uuidString.prefix(4) + " -> " + render(model).debugDescription)
            }
            let diff = l.diffLines()
            // A blank line is only a terminator, and which of several adjacent terminators is "the new one"
            // is not observable. So for blank lines an edit touching a neighbouring line also counts.
            func candidates(blank: Bool, _ match: (ModelLine) -> Bool) -> [ModelLine] {
                var out: [ModelLine] = []
                for (i, m) in model.enumerated() where match(m) {
                    out.append(m)
                    if blank {
                        if i > 0 { out.append(model[i - 1]) }
                        if i + 1 < model.count { out.append(model[i + 1]) }
                    }
                }
                return out
            }
            func short(_ id: UUID) -> String { String(id.uuidString.prefix(4)) }
            let modelDump = model.map { "\($0.text.debugDescription)<\($0.origs.sorted().joined())>{\($0.touchers.map(short).sorted().joined(separator: ","))}" }
            for line in diff {
                switch line {
                case .removed(let text, let edit):
                    let c = candidates(blank: text.isEmpty) { $0.origs.contains(text) }
                    guard !c.isEmpty else { Issue.record("seed \(seed): unknown removed \(text.debugDescription)"); continue }
                    checked += 1
                    #expect(c.contains { $0.touchers.contains(edit) }, "seed \(seed): removed \(text.debugDescription) attributed to unrelated edit \(short(edit)); log \(log) model \(modelDump) diff \(diff)")
                case .added(let text, _, let edit, _):
                    let c = candidates(blank: text.isEmpty) { $0.text == text }
                    guard !c.isEmpty else { Issue.record("seed \(seed): unknown added \(text.debugDescription)"); continue }
                    checked += 1
                    #expect(c.contains { $0.touchers.contains(edit) }, "seed \(seed): added \(text.debugDescription) attributed to unrelated edit \(short(edit)); log \(log) model \(modelDump) diff \(diff)")
                case .context: break
                }
            }
        }
        #expect(checked > 600 && splits > 100 && joins > 50 && deletions > 100, "checked \(checked) splits \(splits) joins \(joins) deletions \(deletions)")
    }
}
