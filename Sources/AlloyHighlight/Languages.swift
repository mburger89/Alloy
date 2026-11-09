import Foundation
import SwiftTreeSitter
import TreeSitterBash
import TreeSitterC
import TreeSitterCPP
import TreeSitterCSS
import TreeSitterGo
import TreeSitterHTML
import TreeSitterJSON
import TreeSitterJavaScript
import TreeSitterMarkdown
import TreeSitterPython
import TreeSitterRust
import TreeSitterSwift
import TreeSitterTSX
import TreeSitterTypeScript
import TreeSitterYAML

/// A language Alloy can highlight with a tree-sitter grammar.
public enum Language: String, CaseIterable, Sendable {
    case swift, python, javascript, typescript, tsx, json, markdown
    case bash, rust, go, c, cpp, yaml, html, css

    /// The language of the file at `path`: by extension, then (for scripts without a known extension) by the
    /// shebang in `firstLine`.
    public static func detect(path: String, firstLine: String? = nil) -> Language? {
        let name = (path as NSString).lastPathComponent
        let ext = (name as NSString).pathExtension.lowercased()
        if let byExtension = extensions[ext] { return byExtension }
        if ext.isEmpty || extensions[ext] == nil, let line = firstLine, line.hasPrefix("#!") {
            return fromShebang(line)
        }
        return nil
    }

    /// The language a Markdown fence's info string names (`js`, `py`, `c++`, ...); `nil` for anything else.
    public static func named(_ fenceName: String) -> Language? {
        let key = fenceName.trimmingCharacters(in: .whitespaces).lowercased()
        return fenceNames[key]
    }

    private static let extensions: [String: Language] = [
        "swift": .swift, "py": .python, "pyi": .python, "pyw": .python,
        "js": .javascript, "mjs": .javascript, "cjs": .javascript, "jsx": .javascript,
        "ts": .typescript, "mts": .typescript, "cts": .typescript, "tsx": .tsx,
        "json": .json, "jsonc": .json, "md": .markdown, "markdown": .markdown,
        "sh": .bash, "bash": .bash, "zsh": .bash, "rs": .rust, "go": .go,
        "c": .c, "h": .c, "cc": .cpp, "cpp": .cpp, "cxx": .cpp, "hpp": .cpp, "hh": .cpp, "hxx": .cpp,
        "yml": .yaml, "yaml": .yaml, "html": .html, "htm": .html, "css": .css,
    ]

    private static let fenceNames: [String: Language] = [
        "swift": .swift, "python": .python, "py": .python, "python3": .python,
        "javascript": .javascript, "js": .javascript, "jsx": .javascript, "node": .javascript, "mjs": .javascript,
        "typescript": .typescript, "ts": .typescript, "tsx": .tsx,
        "json": .json, "jsonc": .json, "markdown": .markdown, "md": .markdown,
        "bash": .bash, "sh": .bash, "shell": .bash, "zsh": .bash, "console": .bash,
        "rust": .rust, "rs": .rust, "go": .go, "golang": .go,
        "c": .c, "h": .c, "cpp": .cpp, "c++": .cpp, "cc": .cpp, "cxx": .cpp, "hpp": .cpp,
        "yaml": .yaml, "yml": .yaml, "html": .html, "css": .css,
    ]

    private static func fromShebang(_ line: String) -> Language? {
        let words = line.dropFirst(2).split(whereSeparator: { $0 == " " || $0 == "/" || $0 == "\t" }).map(String.init)
        for word in words where word != "env" && !word.hasPrefix("-") {
            if word.hasPrefix("python") { return .python }
            if word == "node" || word == "deno" || word == "bun" { return .javascript }
            if ["bash", "sh", "zsh", "dash", "ksh"].contains(word) { return .bash }
        }
        return nil
    }

    /// The grammar's entry point.
    fileprivate var tsLanguage: OpaquePointer {
        switch self {
        case .swift: tree_sitter_swift()
        case .python: tree_sitter_python()
        case .javascript: tree_sitter_javascript()
        case .typescript: tree_sitter_typescript()
        case .tsx: tree_sitter_tsx()
        case .json: tree_sitter_json()
        case .markdown: tree_sitter_markdown()
        case .bash: tree_sitter_bash()
        case .rust: tree_sitter_rust()
        case .go: tree_sitter_go()
        case .c: tree_sitter_c()
        case .cpp: tree_sitter_cpp()
        case .yaml: tree_sitter_yaml()
        case .html: tree_sitter_html()
        case .css: tree_sitter_css()
        }
    }

    /// The highlight query files, in order, as (resource bundle, file name). Grammars that extend another
    /// (TypeScript over JavaScript, C++ over C) list the base queries first.
    fileprivate var queryFiles: [(bundle: String, file: String)] {
        func own(_ name: String, _ file: String = "highlights.scm") -> (bundle: String, file: String) {
            ("TreeSitter\(name)_TreeSitter\(name)", file)
        }
        return switch self {
        case .swift: [own("Swift")]
        case .python: [own("Python")]
        case .javascript: [own("JavaScript"), own("JavaScript", "highlights-jsx.scm")]
        case .typescript: [own("JavaScript"), own("TypeScript")]
        case .tsx: [own("JavaScript"), own("JavaScript", "highlights-jsx.scm"), ("TreeSitterTypeScript_TreeSitterTSX", "highlights.scm")]   // the TypeScript package names the TSX bundle
        case .json: [own("JSON")]
        case .markdown: [own("Markdown")]
        case .bash: [own("Bash")]
        case .rust: [own("Rust")]
        case .go: [own("Go")]
        case .c: [own("C")]
        case .cpp: [own("C"), own("CPP")]
        case .yaml: [own("YAML")]
        case .html: [own("HTML")]
        case .css: [own("CSS")]
        }
    }
}

/// A language's grammar and compiled highlight query, shared by every engine document and fence.
struct LanguageSupport: Sendable {
    let language: SwiftTreeSitter.Language
    let highlights: Query?

    private static let lock = NSLock()
    nonisolated(unsafe) private static var cache: [Language: LanguageSupport] = [:]
    nonisolated(unsafe) private static var reported: Set<String> = []

    /// Logs `message` once per `key`, and trips an assertion in debug builds.
    static func report(_ message: String, key: String) {
        let first = lock.withLock { reported.insert(key).inserted }
        if first {
            NSLog("AlloyHighlight: %@", message)
            assertionFailure(message)
        }
    }

    static func of(_ language: Language) -> LanguageSupport {
        lock.lock()
        if let hit = cache[language] { lock.unlock(); return hit }
        lock.unlock()
        let tsLanguage = SwiftTreeSitter.Language(language.tsLanguage)
        var text = ""
        var missing: [String] = []
        for (bundle, file) in language.queryFiles {
            if let url = queryURL(bundle: bundle, file: file), let part = try? String(contentsOf: url, encoding: .utf8) {
                text += part + "\n"
            } else {
                missing.append("\(bundle)/\(file)")
            }
        }
        if !missing.isEmpty {
            // Not cached: the bundle may appear later (and a cached nil would stick for the process).
            report("highlight queries for \(language) not found: \(missing.joined(separator: ", "))", key: "missing-\(language)")
            return LanguageSupport(language: tsLanguage, highlights: nil)
        }
        var query: Query?
        do {
            query = try Query(language: tsLanguage, data: Data(text.utf8))
        } catch {
            report("highlight query for \(language) failed to compile: \(error)", key: "compile-\(language)")
        }
        let support = LanguageSupport(language: tsLanguage, highlights: query)
        lock.withLock { cache[language] = support }
        return support
    }

    /// `<bundle>.bundle/Contents/Resources/queries/<file>` next to the executable, the app's resources or the
    /// test bundle (SwiftPM puts a dependency's resource bundle beside the products).
    private static func queryURL(bundle: String, file: String) -> URL? {
        var dirs: [URL] = []
        if let url = Bundle.main.resourceURL { dirs.append(url) }
        dirs.append(Bundle.main.bundleURL)
        if let url = Bundle.main.executableURL { dirs.append(url.deletingLastPathComponent()) }
        for b in Bundle.allBundles + Bundle.allFrameworks { dirs.append(b.bundleURL.deletingLastPathComponent()) }
        dirs.append(Bundle(for: BundleToken.self).bundleURL.deletingLastPathComponent())
        let sub = ["Contents/Resources/queries", "queries"]
        for dir in dirs {
            for s in sub {
                let url = dir.appendingPathComponent("\(bundle).bundle/\(s)/\(file)")
                if FileManager.default.isReadableFile(atPath: url.path) { return url }
            }
        }
        return nil
    }

    private final class BundleToken {}
}
