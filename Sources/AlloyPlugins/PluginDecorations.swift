import AlloyCore
import Foundation

/// A colour a plugin may ask for, by name. Alloy maps each to a theme role; a plugin never names a literal colour.
public enum PluginColorRole: String, Sendable, CaseIterable {
    case info, warning, error, success, accent, muted
}

/// What one plugin shows in one document: line items (tint, bar, marker, message row) and range items (underline, tint).
public struct PluginDecorationSet: Equatable, Sendable {
    public struct Mark: Equatable, Sendable {
        public var text: String
        public var role: PluginColorRole
        public init(text: String, role: PluginColorRole) {
            self.text = text
            self.role = role
        }
    }

    public struct LineItem: Equatable, Sendable {
        public var line: Int
        /// Exclusive; nil is the one line.
        public var endLine: Int?
        public var background: PluginColorRole?
        public var gutterBar: PluginColorRole?
        /// One or two characters in the gutter.
        public var marker: Mark?
        /// One line of at most 200 characters under the line.
        public var message: Mark?

        public init(line: Int, endLine: Int? = nil, background: PluginColorRole? = nil, gutterBar: PluginColorRole? = nil,
                    marker: Mark? = nil, message: Mark? = nil) {
            self.line = line
            self.endLine = endLine
            self.background = background
            self.gutterBar = gutterBar
            self.marker = marker
            self.message = message
        }
    }

    public struct RangeItem: Equatable, Sendable {
        /// UTF-8 byte offsets in the text of `version`.
        public var start: Int
        public var end: Int
        public var underline: PluginColorRole?
        public var tint: PluginColorRole?

        public init(start: Int, end: Int, underline: PluginColorRole? = nil, tint: PluginColorRole? = nil) {
            self.start = start
            self.end = end
            self.underline = underline
            self.tint = tint
        }
    }

    public var version: Int
    public var lines: [LineItem]
    public var ranges: [RangeItem]

    public init(version: Int, lines: [LineItem] = [], ranges: [RangeItem] = []) {
        self.version = version
        self.lines = lines
        self.ranges = ranges
    }

    public var isEmpty: Bool { lines.isEmpty && ranges.isEmpty }

    /// The longest message row text.
    public static let maxMessageLength = 200

    /// Parses `decorations/set` params. A bad item (negative line, inverted range, unknown role, a marker that is not one or
    /// two characters, nothing to draw) is dropped and the rest are kept; more than `cap` items keep the first `cap`, lines
    /// before ranges. Nil when the params carry no uri, version or item list.
    public static func parse(_ params: JSONValue, cap: Int) -> (uri: String, set: PluginDecorationSet)? {
        guard let uri = params["uri"]?.stringValue, let version = params["version"]?.intValue,
              let items = params["items"]?.arrayValue else { return nil }
        var lines: [LineItem] = []
        var ranges: [RangeItem] = []
        func role(_ value: JSONValue?, bad: inout Bool) -> PluginColorRole? {
            guard let value else { return nil }
            guard let name = value.stringValue, let role = PluginColorRole(rawValue: name) else { bad = true; return nil }
            return role
        }
        func mark(_ value: JSONValue?, limit: Int, bad: inout Bool) -> Mark? {
            guard let value else { return nil }
            guard var text = value["text"]?.stringValue, let r = role(value["role"], bad: &bad) else { bad = true; return nil }
            text = String(text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).first ?? "")
            if limit == 2 {
                guard (1...2).contains(text.count) else { bad = true; return nil }
            } else {
                if text.count > limit { text = String(text.prefix(limit)) }
                if text.isEmpty { return nil }
            }
            return Mark(text: text, role: r)
        }
        for item in items {
            var bad = false
            if let line = item["line"]?.intValue {
                var endLine: Int?
                if let e = item["endLine"] {
                    guard let value = e.intValue, value > line else { continue }
                    endLine = value
                }
                let background = role(item["background"], bad: &bad)
                let bar = role(item["gutterBar"], bad: &bad)
                let marker = mark(item["marker"], limit: 2, bad: &bad)
                let message = mark(item["message"], limit: maxMessageLength, bad: &bad)
                if line < 0 || bad || (background == nil && bar == nil && marker == nil && message == nil) { continue }
                lines.append(LineItem(line: line, endLine: endLine, background: background, gutterBar: bar, marker: marker,
                                      message: message))
            } else if let start = item["start"]?.intValue, let end = item["end"]?.intValue {
                let underline = role(item["underline"], bad: &bad)
                let tint = role(item["tint"], bad: &bad)
                if start < 0 || start > end || bad || (underline == nil && tint == nil) { continue }
                ranges.append(RangeItem(start: start, end: end, underline: underline, tint: tint))
            }
        }
        let cap = max(0, cap)
        if lines.count > cap { lines = Array(lines.prefix(cap)) }
        if lines.count + ranges.count > cap { ranges = Array(ranges.prefix(cap - lines.count)) }
        return (uri, PluginDecorationSet(version: version, lines: lines, ranges: ranges))
    }
}
