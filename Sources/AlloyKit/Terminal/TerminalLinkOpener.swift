import AlloyCore
import Foundation
import MetalUITerminalUI

/// The process-wide browser hook, set once by the app (`main.swift`); a no-op by default so tests never open a browser.
public enum TerminalLinkHooks {
    @MainActor public static var openURL: (URL) -> Void = { _ in }
}

/// Turns what the terminal view asks about a hovered cell into a link target, and a target back into an action.
/// Pure: the filesystem is reached only through the closure.
enum TerminalLinkOpener {
    /// What activating a target does.
    enum Action: Equatable {
        case openFile(path: String, line: Int)
        case openURL(URL)
    }

    /// Lines past this are not real: the file opens at its first line instead.
    static let maxLine = 10_000_000

    /// The link under `query.cell`, in cell columns. Nil for a non-link, a missing file, or a path outside the project.
    static func target(for query: TerminalLinkQuery, bases: [String], projectRoot: String,
                       fileExists: (String) -> Bool) -> TerminalLinkTarget? {
        // The detector speaks in Character offsets, the view in cells: a wide character takes two.
        let chars = Array(query.rowText)
        var starts: [Int] = []
        starts.reserveCapacity(chars.count + 1)
        var column = 0
        for c in chars { starts.append(column); column += width(c) }
        starts.append(column)
        guard query.cell.col >= 0, query.cell.col < column,
              let index = starts.lastIndex(where: { $0 <= query.cell.col }), index < chars.count,
              let link = LinkDetector.link(at: index, in: query.rowText) else { return nil }
        let columns = starts[link.range.lowerBound]..<starts[link.range.upperBound]
        switch link.kind {
        case .url(let url):
            return TerminalLinkTarget(columns: columns, payload: url)
        case .file(let path, let line, _):
            guard let relative = LinkDetector.resolve(path, bases: bases, projectRoot: projectRoot, fileExists: fileExists)
            else { return nil }
            var n = line ?? 1
            if n < 1 || n > maxLine { n = 1 }
            return TerminalLinkTarget(columns: columns, payload: "file:\(relative):\(n)")
        }
    }

    /// The action for a target's payload; nil for one this opener did not make.
    static func action(for payload: String) -> Action? {
        if payload.hasPrefix("file:") {
            let body = payload.dropFirst("file:".count)
            guard let colon = body.lastIndex(of: ":"), let line = Int(body[body.index(after: colon)...]) else { return nil }
            return .openFile(path: String(body[..<colon]), line: line)
        }
        guard let url = URL(string: payload), let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https"
        else { return nil }
        return .openURL(url)
    }

    /// Terminal cell width of one character: 2 for East Asian wide, fullwidth and emoji presentation, else 1.
    static func width(_ c: Character) -> Int {
        guard let v = c.unicodeScalars.first?.value else { return 1 }
        if c.unicodeScalars.contains(where: { $0.value == 0xFE0F }) { return 2 }
        switch v {
        case 0x1100...0x115F, 0x2E80...0x303E, 0x3041...0x33FF, 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xA000...0xA4CF,
             0xAC00...0xD7A3, 0xF900...0xFAFF, 0xFE30...0xFE6F, 0xFF00...0xFF60, 0xFFE0...0xFFE6,
             0x1F300...0x1F64F, 0x1F900...0x1F9FF, 0x1F680...0x1F6FF, 0x20000...0x3FFFD:
            return 2
        default:
            return 1
        }
    }
}
