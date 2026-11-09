import AlloyHighlight
import Foundation
import MetalUI
import MetalUIMarkdown

/// One parsed `MarkdownDocument` per block id, owned by `TranscriptView` (in `@State`, so a render does not rebuild
/// it) and handed to the lazy rows. A reply that streams in grows by suffix: when `text` extends the cached text only
/// the new bytes are appended (O(token)); any other change parses the text again.
@MainActor
final class MarkdownCache {
    private struct Entry {
        var text: String
        var document: MarkdownDocument
    }

    private var entries: [String: Entry] = [:]
    /// How many times a whole text was parsed (a first sight or a non-extending change). Streaming appends do not count.
    private(set) var parseCount = 0
    /// How many times a suffix was appended to a cached document.
    private(set) var appendCount = 0

    /// The document of `text` for `blockID`. The same text answers the cached document; an extension of the cached text
    /// appends the suffix; anything else parses `text` anew.
    func document(for blockID: String, text: String) -> MarkdownDocument {
        if var entry = entries[blockID] {
            if entry.text == text { return entry.document }
            if text.utf8.count > entry.text.utf8.count, text.utf8.starts(with: entry.text.utf8) {
                entries[blockID] = nil   // let the document be the only holder, so it appends in place
                entry.document.append(String(decoding: text.utf8.dropFirst(entry.text.utf8.count), as: UTF8.self))
                entry.text = text
                entries[blockID] = entry
                appendCount += 1
                return entry.document
            }
        }
        parseCount += 1
        let document = MarkdownDocument(parsing: text)
        entries[blockID] = Entry(text: text, document: document)
        return document
    }
}

/// The transcript's Markdown look. Colours are `ThemeColorKey` tokens. Code lines stay whole inside a horizontal
/// scroller and tables scroll sideways; a vertical wheel over either reaches the transcript (MetalUI 7523f587).
@MainActor
let alloyMarkdownTheme: MarkdownTheme = {
    var theme = MarkdownTheme()
    theme.bodyFont = .system(size: 13)
    theme.headingFonts = [Font.system(size: 20).bold(), Font.system(size: 17).bold(), Font.system(size: 15).bold(),
                          Font.system(size: 14).bold(), Font.system(size: 13).bold(), Font.system(size: 13).bold()]
    theme.codeFont = .system(size: 12, design: .monospaced)
    theme.codeCaptionFont = .system(size: 11)
    theme.inlineCodeBackground = .markdownCodeFill
    theme.codeBlockBackground = .markdownCodeFill
    theme.quoteBar = .markdownQuoteBar
    theme.tableRule = .markdownRule
    theme.codeWraps = false
    theme.tableScrolls = true
    theme.showsCodeCopyButton = true   // MetalUI's own button; also covers fences nested in lists and quotes
    return theme
}()

/// A reply's Markdown as blocks, inside one row of the transcript's lazy stack. Code blocks carry MetalUI's built-in
/// Copy button (`MarkdownTheme.showsCodeCopyButton`, an icon labelled "Copy code", identified `copy-code-<blockID>-<top-level block id>-<n>`). Fences are
/// coloured by `FenceHighlighter`, one shared instance per colour scheme (MetalUI compares a highlighter by identity).
struct MarkdownText: Component {
    let blockID: String
    let text: String
    let cache: MarkdownCache
    @Environment(\.colorScheme) var scheme

    var content: some ElementGroup {
        let document = cache.document(for: blockID, text: text)
        let blockID = blockID
        let scheme = scheme
        VStack(alignment: .leading, spacing: alloyMarkdownTheme.blockSpacing) {
            ForEach(document.blocks, id: \.id) { block in
                MarkdownTopBlock(blockID: blockID, block: block, scheme: scheme).equatable()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// One top-level block; equatable so a streaming token rebuilds only the last one.
struct MarkdownTopBlock: Component, @MainActor Equatable {
    let blockID: String
    let block: MarkdownBlock
    /// The scheme the fences are coloured for; part of the identity so a scheme change rebuilds the block.
    let scheme: ColorScheme

    var content: some ElementGroup {
        MarkdownBlockView(block).markdownTheme(Self.theme(blockID: blockID, blockNumber: block.id))
            .codeHighlighter(FenceHighlighter.shared(for: scheme)).equatable()
    }

    /// MetalUI numbers Copy buttons from 0 within each `MarkdownBlockView`, so the prefix carries the reply's block id
    /// and the top-level block's own id (assigned once by the document and stable while the reply streams):
    /// `copy-code-<blockID>-<block.id>-<n>` is unique in the transcript. The prefix is a function of the stored
    /// values `==` compares, so the equatable fast path is unchanged.
    static func theme(blockID: String, blockNumber: Int) -> MarkdownTheme {
        var theme = alloyMarkdownTheme
        theme.codeCopyButtonIdentifierPrefix = "copy-code-\(blockID)-\(blockNumber)-"
        return theme
    }

    static func == (l: MarkdownTopBlock, r: MarkdownTopBlock) -> Bool { l.blockID == r.blockID && l.block == r.block && l.scheme == r.scheme }
}
