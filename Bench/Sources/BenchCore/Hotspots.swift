import Foundation

public struct HotspotRow: Equatable, Sendable {
    public var name: String
    public var selfValue: Double
    public var totalValue: Double
    public var unit: String
    /// Time Profiler only: summed sample weight in milliseconds, when the export carries weights.
    public var selfMs: Double?
    public var totalMs: Double?

    public init(name: String, selfValue: Double, totalValue: Double, unit: String,
                selfMs: Double? = nil, totalMs: Double? = nil) {
        self.name = name; self.selfValue = selfValue; self.totalValue = totalValue; self.unit = unit
        self.selfMs = selfMs; self.totalMs = totalMs
    }
}

/// A parsed xctrace export element. `ref` elements are resolved through `XDoc.resolve`.
final class XNode {
    let name: String
    var attrs: [String: String]
    var children: [XNode] = []
    var text = ""
    init(name: String, attrs: [String: String]) { self.name = name; self.attrs = attrs }
}

final class XDoc: NSObject, XMLParserDelegate {
    let root = XNode(name: "#root", attrs: [:])
    private var stack: [XNode] = []
    private var ids: [String: XNode] = [:]

    static func parse(_ data: Data) -> XDoc? {
        let d = XDoc(); d.stack = [d.root]
        let p = XMLParser(data: data); p.delegate = d
        return p.parse() ? d : nil
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes attributeDict: [String: String]) {
        let n = XNode(name: elementName, attrs: attributeDict)
        stack.last?.children.append(n)
        if let id = attributeDict["id"], ids[id] == nil { ids[id] = n }
        stack.append(n)
    }
    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        if stack.count > 1 { stack.removeLast() }
    }
    func parser(_ parser: XMLParser, foundCharacters string: String) { stack.last?.text += string }

    /// Follows `ref` attributes to the element that defined the id (children, name and all).
    func resolve(_ node: XNode) -> XNode {
        var n = node, hops = 0
        while let r = n.attrs["ref"], let target = ids[r], hops < 16 { n = target; hops += 1 }
        return n
    }

    func find(_ name: String, in node: XNode? = nil) -> XNode? {
        var seen = Set<ObjectIdentifier>()
        return find(name, node ?? root, &seen)
    }
    private func find(_ name: String, _ node: XNode, _ seen: inout Set<ObjectIdentifier>) -> XNode? {
        let n = resolve(node)
        guard seen.insert(ObjectIdentifier(n)).inserted else { return nil }
        if n.name == name { return n }
        for c in n.children { if let f = find(name, c, &seen) { return f } }
        return nil
    }
    func all(_ name: String, in node: XNode? = nil) -> [XNode] {
        let n = node ?? root
        var out: [XNode] = n.name == name ? [n] : []
        for c in n.children { out += all(name, in: c) }
        return out
    }

    /// Schema name and its column mnemonics in order.
    func schema() -> (name: String, mnemonics: [String])? {
        guard let s = find("schema") else { return nil }
        let mn = s.children.filter { $0.name == "col" }.map { col -> String in
            col.children.first { $0.name == "mnemonic" }?.text.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        }
        return (s.attrs["name"] ?? "unknown", mn)
    }

    /// Each row as mnemonic to resolved cell; sentinels are dropped.
    func rows() -> (schema: String, rows: [[String: XNode]])? {
        guard let (name, mn) = schema() else { return nil }
        let rows = all("row").map { row -> [String: XNode] in
            var cells: [String: XNode] = [:]
            for (i, c) in row.children.enumerated() where i < mn.count && !mn[i].isEmpty {
                let r = resolve(c)
                if r.name != "sentinel" { cells[mn[i]] = r }
            }
            return cells
        }
        return (name, rows)
    }

    func number(_ n: XNode?) -> Double? {
        guard let n else { return nil }
        guard let d = Double(n.text.trimmingCharacters(in: .whitespacesAndNewlines)), d.isFinite else { return nil }
        return d
    }

    /// Frame names of a backtrace, leaf first. Accepts a `backtrace` or `tagged-backtrace` (what real
    /// Time Profiler exports use, frames as direct children), or a cell that contains one.
    func frameNames(_ cell: XNode) -> [String] {
        let kinds: Set<String> = ["backtrace", "tagged-backtrace"]
        guard let bt = kinds.contains(cell.name) ? cell
                : find("backtrace", in: cell) ?? find("tagged-backtrace", in: cell) else { return [] }
        return bt.children.compactMap { c -> String? in
            let f = resolve(c)
            return f.name == "frame" ? f.attrs["name"] : nil
        }
    }
}

public enum Hotspots {
    /// `foo.trace` and `foo.trace/` both give `foo.trace.md`.
    public static func markdownPath(forTrace trace: String) -> String {
        var t = trace
        while t.count > 1, t.hasSuffix("/") { t.removeLast() }
        return t + ".md"
    }

    public static let noRows = "no rows in "
    public static let noSamples = "no samples in time-profile: the app was not on the CPU while recording (an idle app records nothing)"

    /// Top functions by self samples; `totalValue` counts each distinct frame name once per sample.
    public static func timeProfile(xml: Data, top: Int) -> [HotspotRow] {
        guard let doc = XDoc.parse(xml), let (_, rows) = doc.rows() else { return [] }
        var selfN: [String: Double] = [:], totalN: [String: Double] = [:]
        var selfW: [String: Double] = [:], totalW: [String: Double] = [:]
        var anyWeight = false
        for r in rows {
            guard let st = r["stack"] else { continue }
            let names = doc.frameNames(st)
            guard let leaf = names.first else { continue }
            let w = doc.number(r["weight"]).map { anyWeight = true; return $0 / 1_000_000 } ?? 0
            selfN[leaf, default: 0] += 1; selfW[leaf, default: 0] += w
            for n in Set(names) { totalN[n, default: 0] += 1; totalW[n, default: 0] += w }
        }
        var out = totalN.keys.map { n in
            HotspotRow(name: n, selfValue: selfN[n] ?? 0, totalValue: totalN[n] ?? 0, unit: "samples",
                       selfMs: anyWeight ? selfW[n] ?? 0 : nil, totalMs: anyWeight ? totalW[n] : nil)
        }
        out.sort { ($0.selfValue, $0.totalValue, $1.name) > ($1.selfValue, $1.totalValue, $0.name) }
        return Array(out.prefix(top))
    }

    private static let sizeCols = ["size", "bytes"]
    private static let callerCols = ["responsible-caller", "responsible-frame", "backtrace", "stack"]
    private static let liveCols = ["live", "is-live"]

    /// Responsible callers by bytes still live (`selfValue`) and total bytes (`totalValue`).
    public static func allocations(xml: Data, top: Int) -> [HotspotRow] {
        guard let doc = XDoc.parse(xml), let (_, rows) = doc.rows() else { return [] }
        var live: [String: Double] = [:], total: [String: Double] = [:]
        for r in rows {
            guard let size = sizeCols.lazy.compactMap({ doc.number(r[$0]) }).first,
                  let callerCell = callerCols.lazy.compactMap({ r[$0] }).first,
                  let caller = callerName(doc, callerCell) else { continue }
            let isLive = liveCols.lazy.compactMap { r[$0] }.first.map(truthy) ?? false
            total[caller, default: 0] += size
            if isLive { live[caller, default: 0] += size }
        }
        var out = total.map { HotspotRow(name: $0.key, selfValue: live[$0.key] ?? 0, totalValue: $0.value, unit: "bytes") }
        out.sort { ($0.selfValue, $0.totalValue, $1.name) > ($1.selfValue, $1.totalValue, $0.name) }
        return Array(out.prefix(top))
    }

    private static func callerName(_ doc: XDoc, _ cell: XNode) -> String? {
        if let f = doc.frameNames(cell).first { return f }
        if cell.name == "frame", let n = cell.attrs["name"] { return n }
        if let f = doc.find("frame", in: cell), let n = f.attrs["name"] { return n }
        let t = cell.attrs["fmt"] ?? cell.text.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }
    private static func truthy(_ n: XNode) -> Bool {
        let t = (n.attrs["fmt"] ?? n.text).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return ["yes", "true", "1"].contains(t) || n.text.trimmingCharacters(in: .whitespacesAndNewlines) == "1"
    }

    /// Table schema names from `xctrace export --toc`.
    public static func tocSchemas(xml: Data) -> [String] {
        guard let doc = XDoc.parse(xml) else { return [] }
        var seen: [String] = []
        for t in doc.all("table") { if let s = t.attrs["schema"], !seen.contains(s) { seen.append(s) } }
        return seen
    }

    // MARK: report

    public enum Failure: Error, CustomStringConvertible {
        case xctrace(String)
        public var description: String { if case .xctrace(let m) = self { return m }; return "" }
    }

    /// Runs `<executable> xctrace export …` and renders the markdown summary for the trace.
    public static func report(trace: String, top: Int, executable: String = "/usr/bin/xcrun",
                              timeout: TimeInterval = 60) throws -> String {
        let name = (trace as NSString).lastPathComponent
        let toc = try export(executable, ["xctrace", "export", "--input", trace, "--toc"], timeout: timeout)
        let schemas = tocSchemas(xml: toc)
        func table(_ s: String) throws -> Data {
            let d = try export(executable, ["xctrace", "export", "--input", trace, "--xpath",
                                            "/trace-toc/run[@number=\"1\"]/data/table[@schema=\"\(s)\"]"], timeout: timeout)
            guard XDoc.parse(d) != nil else { throw Failure.xctrace("could not parse xctrace export for \(s)") }
            return d
        }
        var out = "# Hotspots: \(name)\n\n"
        if schemas.contains("time-profile") {
            let rows = timeProfile(xml: try table("time-profile"), top: Int.max)
            if rows.isEmpty { return out + noSamples + "\n" }
            out += "Time Profiler, top \(top) functions. Counts are samples.\n\n"
            out += section("By self samples", rows.prefix(top), ms: true)
            let byTotal = rows.sorted { ($0.totalValue, $1.name) > ($1.totalValue, $0.name) }
            out += section("By total samples", byTotal.prefix(top), ms: true)
        } else if let s = schemas.first(where: { $0 == "allocations" }) ?? schemas.first(where: { $0.lowercased().contains("alloc") }) {
            let rows = allocations(xml: try table(s), top: Int.max)
            if rows.isEmpty { return out + noRows + s + "\n" }
            out += "Allocations, top \(top) responsible callers. Sizes are bytes.\n\n"
            out += section("By bytes still live", rows.prefix(top), ms: false)
            let byTotal = rows.sorted { ($0.totalValue, $1.name) > ($1.totalValue, $0.name) }
            out += section("By total bytes", byTotal.prefix(top), ms: false)
        } else {
            out += "Tables in this trace:\n\n" + schemas.map { "- \($0)" }.joined(separator: "\n")
            out += (schemas.isEmpty ? "(none)" : "") + "\n\nOpen the trace in Instruments for this kind: `open \(name)`.\n"
        }
        return out
    }

    private static func section(_ title: String, _ rows: ArraySlice<HotspotRow>, ms: Bool) -> String {
        var s = "## \(title)\n\n"
        guard let first = rows.first else { return s + "(none)\n\n" }
        let alloc = first.unit == "bytes"
        s += alloc ? "| Function | Live bytes | Total bytes |\n|---|---:|---:|\n"
                   : "| Function | Self | Total |\(ms ? " Self ms | Total ms |" : "")\n|---|---:|---:|\(ms ? "---:|---:|" : "")\n"
        for r in rows {
            s += "| \(r.name) | \(Int(r.selfValue)) | \(Int(r.totalValue)) |"
            if !alloc, ms, let a = r.selfMs, let b = r.totalMs { s += String(format: " %.2f | %.2f |", a, b) }
            s += "\n"
        }
        return s + "\n"
    }

    private static func export(_ executable: String, _ args: [String], timeout: TimeInterval) throws -> Data {
        let errPath = NSTemporaryDirectory() + "hotspots-err-\(UUID().uuidString)"
        FileManager.default.createFile(atPath: errPath, contents: nil)
        defer { try? FileManager.default.removeItem(atPath: errPath) }
        let p = Process(); p.executableURL = URL(fileURLWithPath: executable); p.arguments = args
        let pipe = Pipe(); p.standardOutput = pipe
        p.standardError = FileHandle(forWritingAtPath: errPath) ?? FileHandle.nullDevice
        do { try p.run() } catch { throw Failure.xctrace("could not run \(executable): \(error)") }
        let timedOut = TimeoutFlag()
        let pid = p.processIdentifier
        let timer = DispatchWorkItem { if p.isRunning { timedOut.set(); kill(pid, SIGKILL) } }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: timer)
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        timer.cancel()
        if timedOut.isSet { throw Failure.xctrace("xctrace export timed out after \(Int(timeout)) s") }
        guard p.terminationStatus == 0 else {
            let err = (try? String(contentsOfFile: errPath, encoding: .utf8)) ?? ""
            let first = err.split(separator: "\n").first.map(String.init) ?? ""
            throw Failure.xctrace("xctrace export failed (exit \(p.terminationStatus))" + (first.isEmpty ? "" : ": \(first)"))
        }
        return data
    }
}

private final class TimeoutFlag: @unchecked Sendable {
    private let lock = NSLock(); private var flag = false
    func set() { lock.lock(); flag = true; lock.unlock() }
    var isSet: Bool { lock.lock(); defer { lock.unlock() }; return flag }
}
