import Foundation

/// Turns an appcast item's description into text `MarkdownText` can show, from its `sparkle:descriptionFormat`.
/// Markdown and plain text pass through; HTML is reduced to plain text (no web view): tags are removed, block
/// boundaries become line breaks, list items become "- " bullets and the common entities are decoded.
/// A missing format is HTML, as Sparkle documents.
enum ReleaseNotesFormat {
    static func text(_ raw: String?, format: String?) -> String? {
        guard let raw else { return nil }
        switch format?.lowercased() {
        case "markdown", "plain-text": return raw
        default: return plainText(fromHTML: raw)
        }
    }

    /// The format of downloaded notes, from their MIME type (nil when unknown, which reads as HTML).
    static func format(forMIMEType mime: String?) -> String? {
        switch mime?.lowercased() {
        case "text/markdown", "text/x-markdown": "markdown"
        case "text/plain": "plain-text"
        default: nil
        }
    }

    static func plainText(fromHTML html: String) -> String {
        var s = html
        // Script and style bodies are not text.
        for tag in ["script", "style"] {
            s = s.replacingOccurrences(of: "<\(tag)[^>]*>[\\s\\S]*?</\(tag)>", with: "", options: [.regularExpression, .caseInsensitive])
        }
        s = s.replacingOccurrences(of: "<!--[\\s\\S]*?-->", with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: "<br\\s*/?>", with: "\n", options: [.regularExpression, .caseInsensitive])
        s = s.replacingOccurrences(of: "<li[^>]*>", with: "\n- ", options: [.regularExpression, .caseInsensitive])
        s = s.replacingOccurrences(of: "</(p|div|h[1-6]|pre|blockquote)\\s*>", with: "\n\n", options: [.regularExpression, .caseInsensitive])
        s = s.replacingOccurrences(of: "</(ul|ol|tr)\\s*>", with: "\n", options: [.regularExpression, .caseInsensitive])
        s = s.replacingOccurrences(of: "<[^>]*>", with: "", options: .regularExpression)
        for (entity, char) in [("&nbsp;", " "), ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&#39;", "'"), ("&apos;", "'"), ("&amp;", "&")] {
            s = s.replacingOccurrences(of: entity, with: char)
        }
        s = s.replacingOccurrences(of: "[ \\t]+\\n", with: "\n", options: .regularExpression)
        s = s.replacingOccurrences(of: "\\n{3,}", with: "\n\n", options: .regularExpression)
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
