import Foundation

/// Turns an LSP snippet into plain text (Decision 2: the snippet session is not built, so a snippet is inserted as
/// text). Tab stops vanish, a placeholder keeps its default text, a choice keeps its first option, a variable keeps its
/// default or nothing, and the caret goes to `$0` (nil when the snippet has none).
public enum SnippetText {
    /// `caret` is a UTF-8 offset into `text`.
    public static func plain(_ snippet: String) -> (text: String, caret: Int?) {
        var scanner = Scanner(scalars: Array(snippet.unicodeScalars))
        scanner.run(untilCloseBrace: false)
        return (scanner.out, scanner.caret)
    }

    private struct Scanner {
        let scalars: [Unicode.Scalar]
        var i = 0
        var out = ""
        var outBytes = 0
        var caret: Int?

        init(scalars: [Unicode.Scalar]) { self.scalars = scalars }

        private mutating func emit(_ s: Unicode.Scalar) {
            out.unicodeScalars.append(s)
            outBytes += String(s).utf8.count
        }

        private static func isDigit(_ s: Unicode.Scalar) -> Bool { s.value >= 48 && s.value <= 57 }
        private static func isNameStart(_ s: Unicode.Scalar) -> Bool {
            (s.value >= 65 && s.value <= 90) || (s.value >= 97 && s.value <= 122) || s == "_"
        }

        private mutating func digits() -> String {
            var d = ""
            while i < scalars.count, Self.isDigit(scalars[i]) { d.unicodeScalars.append(scalars[i]); i += 1 }
            return d
        }

        private mutating func name() -> String {
            var n = ""
            while i < scalars.count, Self.isNameStart(scalars[i]) || Self.isDigit(scalars[i]) { n.unicodeScalars.append(scalars[i]); i += 1 }
            return n
        }

        /// Emits text until the end, or (inside `${...}`) until the matching `}`, which is consumed.
        mutating func run(untilCloseBrace: Bool) {
            while i < scalars.count {
                let c = scalars[i]
                if c == "}" && untilCloseBrace { i += 1; return }
                if c == "\\" {
                    if i + 1 < scalars.count, scalars[i + 1] == "$" || scalars[i + 1] == "}" || scalars[i + 1] == "\\" {
                        emit(scalars[i + 1]); i += 2
                    } else { emit(c); i += 1 }
                    continue
                }
                if c == "$" { i += 1; dollar(); continue }
                emit(c); i += 1
            }
        }

        private mutating func mark(_ digits: String) {
            if Int(digits) == 0, caret == nil { caret = outBytes }
        }

        /// After a `$`.
        private mutating func dollar() {
            guard i < scalars.count else { emit("$"); return }
            let c = scalars[i]
            if Self.isDigit(c) { mark(digits()); return }
            if Self.isNameStart(c) { _ = name(); return }
            guard c == "{" else { emit("$"); return }
            i += 1
            if i < scalars.count, Self.isDigit(scalars[i]) {
                let d = digits()
                mark(d)
                guard i < scalars.count else { return }
                if scalars[i] == "}" { i += 1 }
                else if scalars[i] == ":" { i += 1; run(untilCloseBrace: true) }
                else if scalars[i] == "|" { i += 1; choice() }
                else { skipToCloseBrace() }
                return
            }
            if i < scalars.count, Self.isNameStart(scalars[i]) {
                _ = name()
                guard i < scalars.count else { return }
                if scalars[i] == "}" { i += 1 }
                else if scalars[i] == ":" { i += 1; run(untilCloseBrace: true) }
                else { skipToCloseBrace() }
                return
            }
            // `${` followed by nothing recognisable: keep it as text.
            emit("$"); emit("{")
        }

        /// Reads `a,b|}` and keeps the first option.
        private mutating func choice() {
            var first = true
            while i < scalars.count {
                let c = scalars[i]
                if c == "\\", i + 1 < scalars.count {
                    if first { emit(scalars[i + 1]) }
                    i += 2
                } else if c == "," { first = false; i += 1 }
                else if c == "|" {
                    i += 1
                    if i < scalars.count, scalars[i] == "}" { i += 1 }
                    return
                } else { if first { emit(c) }; i += 1 }
            }
        }

        private mutating func skipToCloseBrace() {
            var depth = 1
            while i < scalars.count {
                let c = scalars[i]
                if c == "\\" { i += 2; continue }
                if c == "{" { depth += 1 }
                if c == "}" { depth -= 1; if depth == 0 { i += 1; return } }
                i += 1
            }
        }
    }
}
