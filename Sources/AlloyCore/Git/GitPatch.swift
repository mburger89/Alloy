import Foundation

public enum GitPatch {
    /// A single-hunk patch for `git apply --cached --unidiff-zero` (add `-R` to unstage). `hunk` must have no
    /// context. `lineEnding` is the terminator of the file being patched ("\n" or "\r\n"). `noNewlineAtEnd` says
    /// whether the hunk's last removed line (`old`) or last added line (`new`) is the file's final line with no
    /// terminator; it then gets git's "\ No newline at end of file" marker.
    public static func make(path: String, hunk: GitHunk, lineEnding: String, noNewlineAtEnd: (old: Bool, new: Bool)) -> Data {
        let a = name("a/", path), b = name("b/", path)
        var out = "diff --git \(a) \(b)\n--- \(a)\n+++ \(b)\n"
        func range(_ s: Int, _ c: Int) -> String { c == 1 ? "\(s)" : "\(s),\(c)" }
        out += "@@ -\(range(hunk.oldStart, hunk.oldCount)) +\(range(hunk.newStart, hunk.newCount)) @@\n"
        let marker = "\\ No newline at end of file\n"
        for (i, l) in hunk.oldLines.enumerated() {
            let last = i == hunk.oldLines.count - 1
            if last && noNewlineAtEnd.old { out += "-" + l + "\n" + marker } else { out += "-" + l + lineEnding }
        }
        for (i, l) in hunk.newLines.enumerated() {
            let last = i == hunk.newLines.count - 1
            if last && noNewlineAtEnd.new { out += "+" + l + "\n" + marker } else { out += "+" + l + lineEnding }
        }
        return Data(out.utf8)
    }

    /// `prefix + path`, in git's C-style quoting (the quotes wrap the prefix too) when the path has control
    /// characters, quotes, backslashes or non-ASCII bytes.
    static func name(_ prefix: String, _ path: String) -> String {
        let bytes = Array(path.utf8)
        guard bytes.contains(where: { $0 < 0x20 || $0 == 0x22 || $0 == 0x5C || $0 >= 0x7F }) else { return prefix + path }
        var s = "\"" + prefix
        for b in bytes {
            switch b {
            case 0x22: s += "\\\""
            case 0x5C: s += "\\\\"
            case 0x0A: s += "\\n"
            case 0x09: s += "\\t"
            case 0x20..<0x7F: s += String(UnicodeScalar(b))
            default: s += "\\" + String(b, radix: 8).leftPad(3)
            }
        }
        return s + "\""
    }
}

private extension String {
    func leftPad(_ n: Int) -> String { String(repeating: "0", count: max(0, n - count)) + self }
}
