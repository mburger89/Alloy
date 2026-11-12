import Foundation

/// Summarises the `frame-timing.json` Alloy writes when launched with `ALLOY_FRAME_TIMING=1`
/// (`{"schemaVersion":1,"frames":[...]}`). Attribution only: the notes never feed a verdict.
/// Bench has no Alloy dependency, so the file is decoded through this local mirror.
public enum FrameTimingSummary {
    public static let fileName = "frame-timing.json"
    /// Every attribution note starts with this; the publisher strips such notes.
    public static let notePrefix = "Alloy internal ("
    public static let environment = ["ALLOY_FRAME_TIMING": "1"]

    private struct File: Decodable {
        var schemaVersion: Int
        var frames: [Frame]
    }

    private struct Frame: Decodable {
        var kind: String?
        var queueNs: UInt64?
        var buildNs: UInt64
        var encodeNs: UInt64
        var inputToCommitNs: UInt64?
        var inputToPresentedNs: UInt64?
    }

    private static let kindOrder = ["key", "text", "pointer", "wheel", "other"]

    /// One note per input kind present, then one for frames no input caused. Empty for undecodable data.
    public static func notes(from data: Data) -> [String] {
        guard let file = try? JSONDecoder().decode(File.self, from: data), file.schemaVersion == 1 else { return [] }
        let grouped = Dictionary(grouping: file.frames, by: { $0.kind })
        let kinds = grouped.keys.compactMap { $0 }.sorted {
            let a = kindOrder.firstIndex(of: $0) ?? kindOrder.count, b = kindOrder.firstIndex(of: $1) ?? kindOrder.count
            return a == b ? $0 < $1 : a < b
        }
        var out: [String] = []
        for kind in kinds { out.append(note(label: kind, frames: grouped[kind] ?? [])) }
        if let none = grouped[nil], !none.isEmpty { out.append(note(label: "no input", frames: none)) }
        return out
    }

    private static func note(label: String, frames: [Frame]) -> String {
        var parts: [String] = []
        func add(_ name: String, _ values: [UInt64]) {
            guard let m = median(values) else { return }
            parts.append(String(format: "%@ %.1f", name, m / 1e6))
        }
        add("queue", frames.compactMap(\.queueNs))
        add("build", frames.map(\.buildNs))
        add("encode", frames.map(\.encodeNs))
        add("input→commit", frames.compactMap(\.inputToCommitNs))
        add("input→present", frames.compactMap(\.inputToPresentedNs))
        return notePrefix + "\(label), \(frames.count) frames): " + parts.joined(separator: " / ") + " ms median"
    }

    private static func median(_ values: [UInt64]) -> Double? {
        guard !values.isEmpty else { return nil }
        let s = values.sorted()
        let n = s.count
        return n % 2 == 1 ? Double(s[n / 2]) : (Double(s[n / 2 - 1]) + Double(s[n / 2])) / 2
    }
}
