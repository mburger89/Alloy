import Foundation

/// The terminal cursor's shape.
public enum TerminalCursorStyle: String, Codable, Sendable { case block, bar, underline }

/// Terminal preferences, the `terminal` key of settings.json. Every key is optional and lenient: a missing or malformed
/// value takes its default and never costs the other settings.
public struct TerminalSettings: Codable, Equatable, Sendable {
    /// The shell to run; nil starts the user's login shell.
    public var shellPath: String?
    /// The font size in points; nil follows the editor.
    public var fontSize: Double?
    public var scrollbackLines: Int
    public var optionAsMeta: Bool
    public var cursorStyle: TerminalCursorStyle
    public var cursorBlink: Bool
    public var confirmMultilinePaste: Bool

    public static let scrollbackRange = 100...1_000_000
    public static let fontSizeRange = 6.0...72.0

    public init(shellPath: String? = nil, fontSize: Double? = nil, scrollbackLines: Int = 10_000,
                optionAsMeta: Bool = true, cursorStyle: TerminalCursorStyle = .block, cursorBlink: Bool = true,
                confirmMultilinePaste: Bool = true) {
        self.shellPath = Self.cleaned(shellPath)
        self.fontSize = fontSize.map(Self.clamped)
        self.scrollbackLines = min(max(scrollbackLines, Self.scrollbackRange.lowerBound), Self.scrollbackRange.upperBound)
        self.optionAsMeta = optionAsMeta
        self.cursorStyle = cursorStyle
        self.cursorBlink = cursorBlink
        self.confirmMultilinePaste = confirmMultilinePaste
    }

    private enum CodingKeys: String, CodingKey {
        case shellPath, fontSize, scrollbackLines, optionAsMeta, cursorStyle, cursorBlink, confirmMultilinePaste
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = TerminalSettings()
        shellPath = Self.cleaned((try? c.decodeIfPresent(String.self, forKey: .shellPath)) ?? nil)
        fontSize = ((try? c.decodeIfPresent(Double.self, forKey: .fontSize)) ?? nil).flatMap { $0.isFinite ? Self.clamped($0) : nil }
        let lines = (try? c.decodeIfPresent(Int.self, forKey: .scrollbackLines)) ?? nil
        scrollbackLines = lines.map { min(max($0, Self.scrollbackRange.lowerBound), Self.scrollbackRange.upperBound) } ?? d.scrollbackLines
        optionAsMeta = ((try? c.decodeIfPresent(Bool.self, forKey: .optionAsMeta)) ?? nil) ?? d.optionAsMeta
        cursorStyle = ((try? c.decodeIfPresent(TerminalCursorStyle.self, forKey: .cursorStyle)) ?? nil) ?? d.cursorStyle
        cursorBlink = ((try? c.decodeIfPresent(Bool.self, forKey: .cursorBlink)) ?? nil) ?? d.cursorBlink
        confirmMultilinePaste = ((try? c.decodeIfPresent(Bool.self, forKey: .confirmMultilinePaste)) ?? nil) ?? d.confirmMultilinePaste
    }

    private static func cleaned(_ s: String?) -> String? {
        guard let s else { return nil }
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }

    private static func clamped(_ v: Double) -> Double { min(max(v, fontSizeRange.lowerBound), fontSizeRange.upperBound) }
}
