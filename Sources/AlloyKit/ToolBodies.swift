import AlloyCore
import AlloyHighlight
import Foundation
import MetalUI

/// Pure helpers behind the per-kind tool bodies: what text each body shows, and the header chip.
enum ToolBodies {
    static let searchLimit = 50, webLimit = 20, mcpLimit = 30

    /// `1.2 s`; anything under a tenth of a second shows `0.1 s`.
    static func duration(_ seconds: TimeInterval) -> String {
        String(format: "%.1f s", max(0.1, seconds))
    }

    /// The header chip: a shell block shows its duration (and "interrupted"); every other block, and a shell
    /// block with no timing, shows its status word.
    static func trailing(for tool: ToolBlock) -> String {
        guard tool.kind == .shell, let start = tool.startedAt, let end = tool.endedAt,
              tool.status == .succeeded || ((tool.status == .failed || tool.status == .interrupted) && hasShellResult(tool))
        else { return toolStatusWord(tool.status) }
        var chip = duration(end.timeIntervalSince(start))
        if tool.result?["interrupted"]?.boolValue == true { chip += " \u{00B7} interrupted" }
        return chip
    }

    /// Whether the CLI sent a real Bash result object (as opposed to a plain error string).
    static func hasShellResult(_ tool: ToolBlock) -> Bool {
        guard let r = tool.result, r.objectValue != nil else { return false }
        return r["stdout"] != nil || r["stderr"] != nil
    }

    /// Whether the body is the error text: failed and denied calls, and cancelled ones with no real result.
    static func showsFailure(_ tool: ToolBlock) -> Bool {
        switch tool.status {
        case .failed, .denied: true
        case .interrupted: tool.result?.objectValue == nil
        default: false
        }
    }

    /// The header title: the kind's label and the call's summary (shell and todo blocks carry no summary).
    static func title(_ tool: ToolBlock) -> String {
        tool.kind == .shell || tool.kind == .todo || tool.summary.isEmpty ? kindLabel(tool) : "\(kindLabel(tool)) \(tool.summary)"
    }

    /// A failed block wears the error kind's colors and icon.
    static func chromeKind(_ tool: ToolBlock) -> BlockKind {
        tool.status == .failed ? .error : blockKind(tool.kind)
    }

    static func lines(_ text: String) -> [String] {
        var t = Substring(text)
        while t.last == "\n" { t = t.dropLast() }
        return t.isEmpty ? [] : t.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    }

    /// `(stdout lines, stderr lines)` of a shell result; a result without them falls back to the plain text.
    static func shellOutput(_ tool: ToolBlock) -> (out: [String], err: [String]) {
        if let r = tool.result, r["stdout"] != nil || r["stderr"] != nil {
            return (lines(r["stdout"]?.stringValue ?? ""), lines(r["stderr"]?.stringValue ?? ""))
        }
        return (lines(tool.resultText), [])
    }

    /// The file lines of a Read result and the number of the first one. The structured result carries the content
    /// without the CLI's `N\t` prefixes and the real `startLine`; a result with only its text has the prefixes
    /// stripped (and the first number kept) when every line carries one.
    static func readCode(_ tool: ToolBlock) -> (lines: [String], start: Int)? {
        if let file = tool.result?["file"], let content = file["content"]?.stringValue {
            return (lines(content), file["startLine"]?.intValue ?? 1)
        }
        let all = lines(tool.resultText)
        if all.isEmpty { return nil }
        var stripped: [String] = [], first: Int?
        for line in all {
            guard let tab = line.firstIndex(of: "\t"),
                  let n = Int(line[..<tab].trimmingCharacters(in: .whitespaces)) else { return (all, 1) }
            if first == nil { first = n }
            stripped.append(String(line[line.index(after: tab)...]))
        }
        return (stripped, first ?? 1)
    }

    /// The language of the file a Read, Write or Edit block names, by its extension. Never guessed from content.
    static func fileLanguage(_ tool: ToolBlock) -> Language? {
        let path = tool.input["file_path"]?.stringValue ?? tool.result?["file"]?["filePath"]?.stringValue
        return path.flatMap { Language.detect(path: $0) }
    }

    /// The result lines of a search: Grep output lines or file names (made project-relative), Glob file names.
    static func searchLines(_ tool: ToolBlock, root: URL) -> [String] {
        var found: [String] = []
        if let r = tool.result, r.objectValue != nil {
            if let content = r["content"]?.stringValue, !content.isEmpty { found = lines(content) }
            else if let names = r["filenames"]?.arrayValue {
                found = names.compactMap { $0.stringValue }.map { ToolSummary.relativePath($0, root: root) }
            }
        }
        return found.isEmpty ? lines(tool.resultText) : found
    }

    // MARK: shell output colouring

    /// The words of a command that is only a program and plain arguments (quotes allowed); `nil` when it pipes,
    /// chains, redirects, expands (`$`, globs, `~`, braces) or spans lines, since then what it shows is not knowable.
    static func simpleWords(_ command: String) -> [String]? {
        var words: [String] = [], current = "", inWord = false
        var quote: Character?
        for ch in command {
            if let q = quote {
                if ch == q { quote = nil; continue }
                if q == "\"" && (ch == "$" || ch == "`" || ch == "\\") { return nil }
                current.append(ch)
            } else if ch == "'" || ch == "\"" {
                quote = ch; inWord = true
            } else if ch == " " || ch == "\t" {
                if inWord { words.append(current); current = ""; inWord = false }
            } else if "|;&<>$`(){}*?[]~!#\n\\".contains(ch) {
                return nil
            } else {
                current.append(ch); inWord = true
            }
        }
        if quote != nil { return nil }
        if inWord { words.append(current) }
        return words
    }

    /// The file arguments of a `cat`, `head`, `tail`, `sed -n` or `nl` command; `nil` for any other command.
    static func displayedPaths(_ words: [String]) -> (command: String, paths: [String], verbose: Bool)? {
        guard let cmd = words.first else { return nil }
        let args = Array(words.dropFirst())
        switch cmd {
        case "cat":
            guard !args.contains(where: { $0.hasPrefix("-") && $0 != "-" }) else { return nil }
            return (cmd, args, false)
        case "head", "tail", "nl":
            let valued: Set<String> = cmd == "nl" ? ["-b", "-n", "-w", "-s", "-v", "-i", "-l", "-f", "-h", "-d"] : ["-n", "-c"]
            var paths: [String] = [], verbose = false, i = 0
            while i < args.count {
                let a = args[i]
                if a == "-v" { verbose = true } else if valued.contains(a) { i += 1 } else if a.hasPrefix("-") && a != "-" { /* flag */ } else { paths.append(a) }
                i += 1
            }
            return (cmd, paths, verbose)
        case "sed":
            guard args.contains("-n") else { return nil }
            let rest = args.filter { !$0.hasPrefix("-") }
            guard rest.count >= 2 else { return nil }
            return (cmd, Array(rest.dropFirst()), false)
        default: return nil
        }
    }

    /// How a shell result is coloured. Single-file displays use that file's language; "=== path" and
    /// "==> path <==" dumps colour each section by its path; anything else is plain. Never guessed from content.
    static func outputColouring(command: String, output: [String]) -> OutputColouring {
        let words = simpleWords(command)
        let shown = words.flatMap(displayedPaths)
        if let shown, shown.paths.count == 1, !shown.verbose {
            return Language.detect(path: shown.paths[0]).map(OutputColouring.file) ?? .plain
        }
        guard let first = output.first else { return .plain }
        let style: (String) -> String?
        if let shown, shown.command == "head" || shown.command == "tail", shown.paths.count >= 2 || shown.verbose {
            style = arrowHeaderPath
        } else if echoesAndCatsEachFile(command) {
            style = equalsHeaderPath
        } else {
            return .plain
        }
        guard style(first) != nil else { return .plain }
        var sections: [OutputSection] = []
        var start = 0, language: Language?
        for (i, line) in output.enumerated() {
            guard let path = style(line) else { continue }
            if i > 0 { sections.append(OutputSection(lines: start..<i, language: language)) }
            start = i; language = Language.detect(path: path)
        }
        sections.append(OutputSection(lines: start..<output.count, language: language))
        return sections.contains { $0.language != nil } ? .sections(sections) : .plain
    }

    /// Whether the command echoes `=== X` and then, in the same loop or line, `cat`/`head`/`tail`s that same `X`
    /// with nothing piped after it. A heredoc, or an echo followed by anything else, is not a dump.
    static func echoesAndCatsEachFile(_ command: String) -> Bool {
        let pattern = #"echo\s+["']?=== ([^"';\n&|]+?)["']?\s*(?:;|&&|\n)\s*(?:cat|head|tail)\b([^;&|\n]*)(?:;|&&|\n|$)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return false }
        let whole = NSRange(command.startIndex..., in: command)
        let matches = regex.matches(in: command, range: whole)
        guard !matches.isEmpty, !command.contains("<<") else { return false }
        return matches.allSatisfy { m in
            guard let x = Range(m.range(at: 1), in: command), let args = Range(m.range(at: 2), in: command) else { return false }
            return command[args].contains(command[x])
        }
    }

    /// Output lines ready to show: the lines, a gutter number per line (`nil` leaves it blank) and what to colour.
    static func shellOutputView(command: String, output: [String]) -> ShellOutputView {
        let words = simpleWords(command)
        let shown = words.flatMap(displayedPaths)
        var lines = output
        var numbers: [Int?] = (0..<output.count).map { $0 + 1 }
        if let shown, shown.command == "nl", shown.paths.count == 1, let stripped = stripNl(output) {
            lines = stripped.lines; numbers = stripped.numbers
        }
        let colouring = outputColouring(command: command, output: lines)
        if let shown, case .file = colouring, let words {
            switch shown.command {
            case "tail": numbers = Array(repeating: nil, count: lines.count)
            case "sed":
                let script = words.dropFirst().first { !$0.hasPrefix("-") } ?? ""
                if let start = sedStart(script) { numbers = (0..<lines.count).map { start + $0 } }
                else { numbers = Array(repeating: nil, count: lines.count) }
            default: break
            }
        }
        return ShellOutputView(lines: lines, numbers: numbers, plan: colouring.plan(lineCount: lines.count))
    }

    /// The first line a `sed -n` script prints (`40,60p`, `40p`); `nil` for any other script.
    private static func sedStart(_ script: String) -> Int? {
        guard script.hasSuffix("p") else { return nil }
        let range = script.dropLast().split(separator: ",", omittingEmptySubsequences: false)
        guard range.count <= 2, let first = range.first, let n = Int(first) else { return nil }
        if range.count == 2, Int(range[1]) == nil, range[1] != "$" { return nil }
        return n
    }

    /// `nl`'s output without its `N\t` prefixes, and those numbers (blank lines have none); `nil` when a line is neither.
    static func stripNl(_ output: [String]) -> (lines: [String], numbers: [Int?])? {
        var lines: [String] = [], numbers: [Int?] = []
        for line in output {
            if line.allSatisfy({ $0 == " " }) { lines.append(""); numbers.append(nil); continue }
            guard let tab = line.firstIndex(of: "\t"), let n = Int(line[..<tab].trimmingCharacters(in: .whitespaces)) else { return nil }
            lines.append(String(line[line.index(after: tab)...])); numbers.append(n)
        }
        return (lines, numbers)
    }

    private static func arrowHeaderPath(_ line: String) -> String? {
        guard line.hasPrefix("==> "), line.hasSuffix(" <==") else { return nil }
        let path = line.dropFirst(4).dropLast(4)
        return path.isEmpty ? nil : String(path)
    }

    private static func equalsHeaderPath(_ line: String) -> String? {
        guard line.hasPrefix("=== ") else { return nil }
        var path = Substring(line.dropFirst(4))
        if path.hasSuffix(" ===") { path = path.dropLast(4) }
        let trimmed = path.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? nil : trimmed
    }

    struct TodoItem { let index: Int; let text: String }

    /// The TodoWrite checklist: ✓ done, ● in progress, ○ pending.
    static func todoItems(_ tool: ToolBlock) -> [TodoItem] {
        (tool.input["todos"]?.arrayValue ?? []).enumerated().map { i, todo in
            let glyph = switch todo["status"]?.stringValue {
            case "completed": "\u{2713}"
            case "in_progress": "\u{25CF}"
            default: "\u{25CB}"
            }
            return TodoItem(index: i, text: "\(glyph) \(todo["content"]?.stringValue ?? "")")
        }
    }

    static func prettyJSON(_ value: JSONValue) -> [String] {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(value), let text = String(data: data, encoding: .utf8) else { return [] }
        return lines(text)
    }
}

struct ShellOutputView: Equatable {
    var lines: [String]
    var numbers: [Int?]
    var plan: [OutputSection]
}

/// A run of output lines (a section header included as its first line) in one language.
struct OutputSection: Equatable, Sendable {
    var lines: Range<Int>
    var language: Language?
}

enum OutputColouring: Equatable, Sendable {
    case plain
    case file(Language)
    case sections([OutputSection])

    /// What to highlight, as line ranges: the whole output for a file; each section's body (not its header line)
    /// for a dump.
    func plan(lineCount: Int) -> [OutputSection] {
        switch self {
        case .plain: []
        case .file(let language): [OutputSection(lines: 0..<lineCount, language: language)]
        case .sections(let sections):
            sections.compactMap { s in
                guard let language = s.language, s.lines.count > 1 else { return nil }
                return OutputSection(lines: (s.lines.lowerBound + 1)..<s.lines.upperBound, language: language)
            }
        }
    }
}

/// The body of a tool block, by kind. Edit and write diffs are drawn by `DiffSection`, not here.
struct ToolBody: Component {
    let tool: ToolBlock
    let root: URL
    /// The expand state and cached rows of the session's code blocks (kept in `SessionUIStore`).
    let codeState: CodeBlockState
    /// Opens the block's file at a line, for Read blocks of files inside the project.
    var openFile: ((Int?) -> Void)?
    let showPrompt: Binding<Bool>

    var content: some ElementGroup {
        VStack(alignment: .leading, spacing: Pixels(4)) {
            if ToolBodies.showsFailure(tool) {
                failure
            } else {
                switch tool.kind {
                case .shell: shell
                case .read: read
                case .search: capped(ToolBodies.searchLines(tool, root: root), limit: ToolBodies.searchLimit)
                case .web: capped(ToolBodies.lines(tool.resultText), limit: ToolBodies.webLimit)
                case .subagent: subagent
                case .todo: todo
                case .mcp: capped(ToolBodies.prettyJSON(tool.input), limit: ToolBodies.mcpLimit)
                default: stopgap
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ElementBuilder
    private func box(_ text: String, ink: Color? = nil) -> some ElementGroup {
        if !text.isEmpty {
            if let ink {
                Text(verbatim: text).font(family: "Menlo", size: 11).foregroundColor(ink)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Text(verbatim: text).font(family: "Menlo", size: 11)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    @ElementBuilder
    private var failure: some ElementGroup {
        if tool.kind == .shell { command(ToolBodies.lines(tool.input["command"]?.stringValue ?? ""), fingerprint: nil) }
        code("error", ToolBodies.lines(tool.resultText), ink: .errorInk, overflow: .copyAll)
    }

    @ElementBuilder
    private func command(_ lines: [String], fingerprint: Int?) -> some ElementGroup {
        if !lines.isEmpty {
            let id = "\(tool.toolUseID)-command"
            let fingerprint = fingerprint ?? Self.fingerprint(lines, plan: [], start: 1, numbers: nil)
            ChatCodeBlock(blockID: tool.toolUseID, part: "command", expanded: codeState.binding(id),
                          item: codeState.store.item(id: id, fingerprint: fingerprint) {
                              (lines.enumerated().map { CodeLine(text: $1, number: $0 + 1) },
                               [OutputSection(lines: 0..<lines.count, language: .bash)])
                          })
        }
    }

    /// A code block of `text`, numbered from `start` (or by `numbers`), coloured per `plan`. `fingerprint` is given
    /// when the caller already hashed the text (the cached shell output).
    @ElementBuilder
    private func code(_ part: String, _ text: [String], plan: [OutputSection] = [], start: Int = 1, numbers: [Int?]? = nil,
                      fingerprint: Int? = nil, ink: Color? = nil, overflow: CodeOverflow = .count) -> some ElementGroup {
        if !text.isEmpty {
            let id = "\(tool.toolUseID)-\(part)"
            let fingerprint = fingerprint ?? Self.fingerprint(text, plan: plan, start: start, numbers: numbers)
            ChatCodeBlock(blockID: tool.toolUseID, part: part, expanded: codeState.binding(id),
                          item: codeState.store.item(id: id, fingerprint: fingerprint) {
                              (text.enumerated().map { i, line in CodeLine(text: line, number: numbers.map { $0[i] } ?? (start + i)) }, plan)
                          }, ink: ink, overflow: overflow)
        }
    }

    private static func fingerprint(_ text: [String], plan: [OutputSection], start: Int, numbers: [Int?]?) -> Int {
        var h = Hasher()
        for line in text { h.combine(line) }
        h.combine(start)
        for section in plan { h.combine(section.lines.lowerBound); h.combine(section.lines.upperBound); h.combine(section.language) }
        if let numbers { h.combine(numbers) }
        return h.finalize()
    }

    /// Everything a shell block derives from its input: split lines, nl stripping, colouring and the fingerprints.
    struct ShellDerived {
        var command: [String]
        var commandFingerprint: Int
        var output: ShellOutputView
        var outputFingerprint: Int
        var err: [String]
        var errFingerprint: Int
    }

    /// Changes whenever the block's input can have: it ends, its status changes, or more output has streamed in
    /// (output lengths; `utf8.count` is O(1) on native strings).
    private var shellKey: Int {
        var h = Hasher()
        h.combine(tool.endedAt)
        h.combine(tool.status)
        h.combine(tool.input["command"]?.stringValue?.utf8.count)
        h.combine(tool.resultText.utf8.count)
        h.combine(tool.result?["stdout"]?.stringValue?.utf8.count)
        h.combine(tool.result?["stderr"]?.stringValue?.utf8.count)
        return h.finalize()
    }

    @ElementBuilder
    private var shell: some ElementGroup {
        let tool = tool
        let derived = codeState.store.memo("\(tool.toolUseID)-shell", key: shellKey) { () -> ShellDerived in
            let text = tool.input["command"]?.stringValue ?? ""
            let output = ToolBodies.shellOutput(tool)
            let view = ToolBodies.shellOutputView(command: text, output: output.out)
            let command = ToolBodies.lines(text)
            return ShellDerived(
                command: command, commandFingerprint: Self.fingerprint(command, plan: [], start: 1, numbers: nil),
                output: view, outputFingerprint: Self.fingerprint(view.lines, plan: view.plan, start: 1, numbers: view.numbers),
                err: output.err, errFingerprint: Self.fingerprint(output.err, plan: [], start: 1, numbers: nil))
        }
        command(derived.command, fingerprint: derived.commandFingerprint)
        code("output", derived.output.lines, plan: derived.output.plan, numbers: derived.output.numbers,
             fingerprint: derived.outputFingerprint, overflow: .copyAll)
        code("stderr", derived.err, fingerprint: derived.errFingerprint, ink: .errorInk, overflow: .copyAll)
    }

    @ElementBuilder
    private var read: some ElementGroup {
        if let file = ToolBodies.readCode(tool) {
            let plan = ToolBodies.fileLanguage(tool).map { [OutputSection(lines: 0..<file.lines.count, language: $0)] } ?? []
            code("content", file.lines, plan: plan, start: file.start, overflow: openFile.map(CodeOverflow.openFile) ?? .count)
        }
    }

    /// Monospace lines, the first `limit` of them, with a note for the rest.
    @ElementBuilder
    private func capped(_ all: [String], limit: Int) -> some ElementGroup {
        box(all.prefix(limit).joined(separator: "\n"))
        if all.count > limit {
            Text(verbatim: "\u{2026} \(all.count - limit) more lines").font(size: 11).foregroundColor(.mutedInk)
        }
    }

    @ElementBuilder
    private var subagent: some ElementGroup {
        let showPrompt = showPrompt
        let open = showPrompt.wrappedValue
        Button(open ? "Hide prompt" : "Show prompt") { showPrompt.wrappedValue.toggle() }
            .accessibilityIdentifier("prompt-toggle-\(tool.toolUseID)")
        if open { box(tool.input["prompt"]?.stringValue ?? "") }
        if !tool.resultText.isEmpty {
            Text(verbatim: tool.resultText).font(size: 12)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ElementBuilder
    private var todo: some ElementGroup {
        ForEach(ToolBodies.todoItems(tool), id: \.index) { item in
            Text(verbatim: item.text).font(size: 12)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// Kinds without a dedicated body: the result text as a plain code block.
    @ElementBuilder
    private var stopgap: some ElementGroup {
        code("output", ToolBodies.lines(tool.resultText), overflow: .copyAll)
    }
}
