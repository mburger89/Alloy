import AlloyLSP
import Foundation
import MetalUI

/// The hover popover's content: the diagnostics under the pointer (message, source, code), then the server's Markdown.
@MainActor
struct HoverView: Component {
    let presentation: HoverPresentation
    let cache: MarkdownCache

    var content: some ElementGroup {
        let presentation = presentation, cache = cache
        ScrollView {
            VStack(alignment: .leading, spacing: Pixels(8)) {
                ForEach(Array(presentation.diagnostics.enumerated()), id: \.offset) { i, item in
                    VStack(alignment: .leading, spacing: Pixels(2)) {
                        Text(verbatim: item.message).font(size: 12).foregroundColor(Self.ink(item.severity))
                        if let detail = Self.detail(item) {
                            Text(verbatim: detail).font(size: 11).foregroundColor(.mutedInk)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("hover-diagnostic-\(i)")
                }
                if !presentation.markdown.isEmpty {
                    MarkdownText(blockID: "hover", text: presentation.markdown, cache: cache)
                }
            }
            .padding(inset(12, 8))
        }
        .frame(maxWidth: Pixels(520))
        .frame(maxHeight: Pixels(320))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("hover-popover")
    }

    /// "source (code)", whichever of the two the server gave.
    static func detail(_ item: LSPDiagnostic) -> String? {
        switch (item.source, item.code) {
        case let (source?, code?): "\(source) (\(code))"
        case let (source?, nil): source
        case let (nil, code?): code
        case (nil, nil): nil
        }
    }

    static func ink(_ severity: Severity) -> Color {
        switch severity {
        case .error: .diagnosticError
        case .warning: .diagnosticWarning
        case .information, .hint: .diagnosticInfo
        }
    }
}
