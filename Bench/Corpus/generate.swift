// Deterministic benchmark corpus generator (seeded LCG).
//   swift Bench/Corpus/generate.swift            write small/medium/large.rs + MANIFEST.sha256
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

/// One block of valid-looking Rust (never compiled): the `kind` picks a construct, `i` makes names unique.
func block(_ i: Int, _ rng: inout LCG) -> [String] {
    let ops = ["+", "-", "*", "^", "|", "&"]
    let words = ["alpha", "beta", "gamma", "delta", "omega", "sigma", "kappa", "theta", "lambda", "zeta"]
    let w = words[rng.below(words.count)]
    let cap = String(w.prefix(1)).uppercased() + String(w.dropFirst())
    var l: [String] = []
    switch rng.below(7) {
    case 0:  // plain function with arithmetic
        l.append("/// Mixes `x` and `y` for block \(i).")
        l.append("pub fn sample\(i)(x: u64, y: u64) -> u64 {")
        var prev = "x"
        for s in 0..<(1 + rng.below(4)) {
            l.append("    let v\(s) = \(prev) \(ops[rng.below(ops.count)]) \(rng.below(100_000)) \(ops[rng.below(ops.count)]) y;")
            prev = "v\(s)"
        }
        l.append("    \(prev)")
        l.append("}")
    case 1:  // struct with derive and impl
        l.append("#[derive(Debug, Clone, PartialEq)]")
        l.append("pub struct \(cap)\(i) {")
        l.append("    pub name: String,")
        l.append("    pub count: usize,")
        l.append("    weight: f64,")
        l.append("}")
        l.append("")
        l.append("impl \(cap)\(i) {")
        l.append("    pub fn new(name: &str, count: usize) -> Self {")
        l.append("        Self { name: name.to_string(), count, weight: \(rng.below(100)).\(rng.below(100))_f64 }")
        l.append("    }")
        l.append("")
        l.append("    pub fn score(&self) -> f64 {")
        l.append("        self.weight * self.count as f64 // scaled by count")
        l.append("    }")
        l.append("}")
    case 2:  // enum and match
        l.append("#[derive(Debug, Copy, Clone)]")
        l.append("enum Kind\(i) {")
        l.append("    Small,")
        l.append("    Medium(u32),")
        l.append("    Large { width: u32, height: u32 },")
        l.append("}")
        l.append("")
        l.append("fn describe\(i)(k: Kind\(i)) -> String {")
        l.append("    match k {")
        l.append("        Kind\(i)::Small => String::from(\"small \(w)\"),")
        l.append("        Kind\(i)::Medium(n) if n > \(rng.below(1000)) => format!(\"medium {} over\", n),")
        l.append("        Kind\(i)::Medium(n) => format!(\"medium {}\", n),")
        l.append("        Kind\(i)::Large { width, height } => format!(\"{}x{}\", width, height),")
        l.append("    }")
        l.append("}")
    case 3:  // generic function with closure and iterators
        l.append("pub fn collect\(i)<T: Clone + Into<u64>>(items: &[T], limit: usize) -> Vec<u64> {")
        l.append("    items")
        l.append("        .iter()")
        l.append("        .map(|item| item.clone().into() * \(1 + rng.below(9)))")
        l.append("        .filter(|&n| n % \(2 + rng.below(7)) == 0)")
        l.append("        .take(limit)")
        l.append("        .collect()")
        l.append("}")
    case 4:  // trait and impl
        l.append("pub trait Shape\(i) {")
        l.append("    fn area(&self) -> f64;")
        l.append("    fn label(&self) -> &'static str {")
        l.append("        \"\(w)\"")
        l.append("    }")
        l.append("}")
        l.append("")
        l.append("struct Square\(i)(f64);")
        l.append("")
        l.append("impl Shape\(i) for Square\(i) {")
        l.append("    fn area(&self) -> f64 {")
        l.append("        self.0 * self.0")
        l.append("    }")
        l.append("}")
    case 5:  // Result, loop, early return
        l.append("fn parse\(i)(input: &str) -> Result<Vec<i32>, std::num::ParseIntError> {")
        l.append("    let mut out = Vec::new();")
        l.append("    for (n, part) in input.split(',').enumerate() {")
        l.append("        /* skip every \(2 + rng.below(5))th entry */")
        l.append("        if n % \(2 + rng.below(5)) == 1 {")
        l.append("            continue;")
        l.append("        }")
        l.append("        out.push(part.trim().parse::<i32>()?);")
        l.append("    }")
        l.append("    Ok(out)")
        l.append("}")
    default:  // constants, static, and a test
        l.append("const LIMIT_\(i): usize = \(rng.below(100_000));")
        l.append("static NAMES_\(i): [&str; 3] = [\"\(w)\", \"\(words[rng.below(words.count)])\", \"\(words[rng.below(words.count)])\"];")
        l.append("")
        l.append("#[cfg(test)]")
        l.append("mod tests\(i) {")
        l.append("    #[test]")
        l.append("    fn limit_is_sane() {")
        l.append("        assert!(super::LIMIT_\(i) < 100_000, \"limit {} too big\", super::LIMIT_\(i));")
        l.append("    }")
        l.append("}")
    }
    l.append("")
    return l
}

/// Exactly `lines` lines of valid-looking Rust: seeded random blocks, then comment padding.
func generate(lines: Int, seed: UInt64) -> String {
    var rng = LCG(state: seed)
    var out: [String] = ["// Deterministic benchmark corpus (seed \(seed)); not meant to compile.", "use std::collections::HashMap;", ""]
    out.reserveCapacity(lines)
    var i = 0
    while true {
        let b = block(i, &rng)
        if out.count + b.count > lines { break }
        out.append(contentsOf: b)
        i += 1
    }
    while out.count < lines { out.append("// padding \(out.count)") }
    return out.joined(separator: "\n") + "\n"
}

let specs: [(name: String, lines: Int, seed: UInt64)] = [
    ("small.rs", 200, 1), ("medium.rs", 5_000, 2), ("large.rs", 100_000, 3),
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
