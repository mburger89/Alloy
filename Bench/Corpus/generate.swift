// Deterministic benchmark corpus generator (seeded LCG).
//   swift Bench/Corpus/generate.swift            write small/medium/large.swift + MANIFEST.sha256
//   swift Bench/Corpus/generate.swift --verify   check committed files against MANIFEST.sha256
import CryptoKit
import Foundation

struct LCG {
    var state: UInt64
    mutating func next() -> UInt64 {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return state >> 33
    }
    mutating func below(_ n: Int) -> Int { Int(next() % UInt64(n)) }
}

/// Exactly `lines` lines of syntactically valid Swift: seeded random functions, then comment padding.
func generate(lines: Int, seed: UInt64) -> String {
    var rng = LCG(state: seed)
    var out: [String] = []
    out.reserveCapacity(lines)
    var i = 0
    let ops = ["&+", "&-", "&*", "^", "|", "&"]
    while true {
        let stmts = 1 + rng.below(4)
        let size = 1 + 1 + stmts + 1 + 1 + 1  // comment, signature, stmts, return, close, blank
        if out.count + size > lines { break }
        out.append("// block \(i): seeded sample code")
        out.append("func sample\(i)(_ x: Int, _ y: Int) -> Int {")
        var prev = "x"
        for s in 0..<stmts {
            out.append("    let v\(s) = \(prev) \(ops[rng.below(ops.count)]) \(rng.below(100_000)) \(ops[rng.below(ops.count)]) y")
            prev = "v\(s)"
        }
        out.append("    return \(prev)")
        out.append("}")
        out.append("")
        i += 1
    }
    while out.count < lines { out.append("// padding \(out.count)") }
    return out.joined(separator: "\n") + "\n"
}

let specs: [(name: String, lines: Int, seed: UInt64)] = [
    ("small.swift", 200, 1), ("medium.swift", 5_000, 2), ("large.swift", 100_000, 3),
]

func sha256(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
let manifestURL = dir.appendingPathComponent("MANIFEST.sha256")

if CommandLine.arguments.contains("--verify") {
    let manifest = (try? String(contentsOf: manifestURL, encoding: .utf8)) ?? ""
    var ok = true
    for s in specs {
        let fresh = Data(generate(lines: s.lines, seed: s.seed).utf8)
        let onDisk = (try? Data(contentsOf: dir.appendingPathComponent(s.name))) ?? Data()
        let line = "\(sha256(fresh))  \(s.name)"
        if onDisk != fresh || !manifest.contains(line) { print("MISMATCH \(s.name)"); ok = false }
    }
    print(ok ? "corpus OK" : "corpus MISMATCH")
    exit(ok ? 0 : 1)
}

var manifest = ""
for s in specs {
    let data = Data(generate(lines: s.lines, seed: s.seed).utf8)
    try data.write(to: dir.appendingPathComponent(s.name))
    manifest += "\(sha256(data))  \(s.name)\n"
}
try manifest.write(to: manifestURL, atomically: true, encoding: .utf8)
print("wrote corpus:\n" + manifest)
