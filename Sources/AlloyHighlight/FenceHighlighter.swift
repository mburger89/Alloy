import MetalUI
import SwiftTreeSitter

/// Colours the code of chat Markdown fences. It parses each fence with a throwaway parser, synchronously;
/// MetalUI calls it once per change of a fence and holds it by identity, so keep one instance per scheme.
public final class FenceHighlighter: MarkdownCodeHighlighter, @unchecked Sendable {
    /// Fences over this many lines stay plain.
    public static let maxLines = 2_000
    /// Fences over this many UTF-8 bytes stay plain.
    public static let maxBytes = 64 * 1024

    /// One shared instance per scheme, so the view's identity comparison holds across renders.
    public static let light = FenceHighlighter(scheme: .light)
    public static let dark = FenceHighlighter(scheme: .dark)

    public static func shared(for scheme: ColorScheme) -> FenceHighlighter {
        scheme == .dark ? dark : light
    }

    private let styles: [SyntaxToken: CodeStyle]

    public init(scheme: ColorScheme, palette: SyntaxPalette = SyntaxPalette()) {
        var styles: [SyntaxToken: CodeStyle] = [:]
        for token in SyntaxToken.allCases { styles[token] = palette.style(token, scheme: scheme) }
        self.styles = styles
    }

    public func highlight(code: String, language: String?, isClosed: Bool) -> [MarkdownCodeRun] {
        guard let name = language, let lang = Language.named(name) else { return [] }
        let bytes = Array(code.utf8)
        if bytes.count > Self.maxBytes { return [] }
        var lines = 0
        for b in bytes where b == 0x0A { lines += 1 }
        if let last = bytes.last, last != 0x0A { lines += 1 }   // a trailing newline ends a line, it does not start one
        if lines > Self.maxLines { return [] }
        let support = LanguageSupport.of(lang)
        guard let query = support.highlights else { return [] }
        let parser = Parser()
        guard (try? parser.setLanguage(support.language)) != nil,
              let tree = HighlightCore.parse(parser, old: nil, bytes: bytes) else { return [] }
        return HighlightCore.runs(tree: tree, query: query, bytes: bytes, range: 0..<bytes.count).compactMap { range, token in
            guard let style = styles[token], style.foreground != nil else { return nil }
            return MarkdownCodeRun(range: range, style: style)
        }
    }
}
