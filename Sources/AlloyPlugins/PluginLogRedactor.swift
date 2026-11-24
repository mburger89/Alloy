import Foundation

/// Hides credentials in text a plugin wrote to its log: each known secret value verbatim, then common token shapes.
public enum PluginLogRedactor {
    public static let marker = "\u{2039}redacted\u{203A}"

    private static let patterns: [NSRegularExpression] = [
        #"Bearer\s+\S+"#,
        #"sk-[A-Za-z0-9_-]+"#,
        #"ghp_[A-Za-z0-9]+"#,
        #"github_pat_[A-Za-z0-9_]+"#,
        #"xox[abposr]-[A-Za-z0-9-]+"#,
        #"AKIA[0-9A-Z]{16}"#,
        #"[A-Za-z0-9+/=_-]{32,}"#,
    ].compactMap { try? NSRegularExpression(pattern: $0) }

    public static func redact(_ text: String, secrets: [String] = []) -> String {
        var out = text
        for secret in secrets where !secret.isEmpty { out = out.replacingOccurrences(of: secret, with: marker) }
        for pattern in patterns {
            out = pattern.stringByReplacingMatches(in: out, range: NSRange(out.startIndex..., in: out),
                                                   withTemplate: NSRegularExpression.escapedTemplate(for: marker))
        }
        return out
    }
}
