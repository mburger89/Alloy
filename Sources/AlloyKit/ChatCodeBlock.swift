import AlloyHighlight
import Foundation
import MetalUI

/// One line of a chat code block.
struct CodeLine: Equatable {
    var text: String
    /// The gutter number; `nil` leaves the gutter blank (a removed diff line).
    var number: Int?
    /// A diff mark (`+`, `-`, space); `nil` for blocks that are not diffs.
    var mark: String?
    var tint: Color?
}

/// What the note under a block that shows fewer lines than it has says and does.
enum CodeOverflow {
    /// "N more lines".
    case count
    /// "Copy to get all N lines" (shell output: Copy already copies everything).
    case copyAll
    /// "N more lines" and an "Open file" button that opens the file at the first hidden line.
    case openFile((Int?) -> Void)
}

/// Syntax colours for chat code blocks, from the engine that colours Markdown fences. Pure and `Sendable`, so a
/// block computes it off the main actor.
enum CodeHighlight {
    private final class Log: @unchecked Sendable {
        let lock = NSLock()
        var entries: [String: [Int]] = [:]
    }
    private static let log = Log()

    /// How many lines each highlight request for the block tagged `tag` (`<blockID>-<part>`) covered, oldest first.
    /// A test hook: proves a collapsed block asks for its visible lines only.
    static func requests(tag: String) -> [Int] { log.lock.withLock { log.entries[tag] ?? [] } }

    /// `lines` as attributed text: each plan section's lines are parsed together in its language and coloured with the
    /// fence palette. Lines outside every section, and everything over `FenceHighlighter`'s caps, stay plain. Returns
    /// `nil` as soon as the running task is cancelled.
    static func attributed(lines: [String], plan: [OutputSection], scheme: ColorScheme, tag: String?) -> [AttributedString]? {
        if let tag { log.lock.withLock { log.entries[tag, default: []].append(lines.count) } }
        var out = lines.map { AttributedString($0) }
        let highlighter = FenceHighlighter.shared(for: scheme)
        for section in plan {
            guard let language = section.language else { continue }
            if Task.isCancelled { return nil }
            let range = section.lines.clamped(to: 0..<lines.count)
            if range.isEmpty { continue }
            let text = lines[range].joined(separator: "\n")
            let runs = highlighter.highlight(code: text, language: language.rawValue, isClosed: true)
                .sorted { $0.range.lowerBound < $1.range.lowerBound }
            if runs.isEmpty { continue }
            var lineStart = 0, next = 0
            for index in range {
                if Task.isCancelled { return nil }
                let line = lines[index]
                let lineEnd = lineStart + line.utf8.count
                out[index] = paint(line, from: lineStart, to: lineEnd, runs: runs, next: &next)
                lineStart = lineEnd + 1
            }
        }
        return Task.isCancelled ? nil : out
    }

    /// ``attributed(lines:plan:scheme:tag:)`` on a background task that is cancelled with the caller.
    static func compute(lines: [String], plan: [OutputSection], scheme: ColorScheme, tag: String) async -> [AttributedString]? {
        let work = Task.detached(priority: .userInitiated) { attributed(lines: lines, plan: plan, scheme: scheme, tag: tag) }
        return await withTaskCancellationHandler { await work.value } onCancel: { work.cancel() }
    }

    private static func paint(_ line: String, from start: Int, to end: Int, runs: [MarkdownCodeRun], next: inout Int) -> AttributedString {
        var result = AttributedString()
        let bytes = Array(line.utf8)
        var cursor = start
        func piece(_ a: Int, _ b: Int, _ color: Color?) {
            guard b > a else { return }
            var part = AttributedString(String(decoding: bytes[(a - start)..<(b - start)], as: UTF8.self))
            if let color { part.foregroundColor = color }
            result.append(part)
        }
        while next < runs.count, runs[next].range.lowerBound < end {
            let run = runs[next]
            if run.range.upperBound <= cursor { next += 1; continue }   // overlaps what was already painted
            let a = max(run.range.lowerBound, cursor), b = min(run.range.upperBound, end)
            piece(cursor, a, nil)
            piece(a, b, run.style.foreground)
            cursor = max(cursor, b)
            if run.range.upperBound <= end { next += 1 } else { break }
        }
        piece(cursor, end, nil)
        return result
    }
}

/// One code block's lines, built once per input, with the colours computed so far and the rows built from them. It keeps
/// the lines a block can show (at most `maxRows + 1`, so the one after the last tells where the rest begins) and the
/// whole text once, as a String, for Copy.
@MainActor
final class CodeBlockItem {
    let fingerprint: Int
    let lines: [CodeLine]
    /// How many lines the input has.
    let total: Int
    let fullText: String
    let plan: [OutputSection]
    let gutterDigits: Int
    let hasMarks: Bool
    /// Colours of `lines[0..<colours.count]` for `scheme`. They stay until newer ones replace them.
    var colours: [AttributedString] = [] { didSet { generation += 1 } }
    var scheme: ColorScheme? { didSet { generation += 1 } }
    /// Bumped on every change of what the rows show, so a cached row set is never reused for different colours.
    private var generation = 0
    private var rowCache: (shown: Int, generation: Int, rows: [CodeRowModel])?

    init(fingerprint: Int, lines: [CodeLine], plan: [OutputSection]) {
        self.fingerprint = fingerprint
        self.plan = plan
        total = lines.count
        fullText = lines.map(\.text).joined(separator: "\n")
        self.lines = Array(lines.prefix(ChatCodeBlock.maxRows + 1))
        gutterDigits = max(String(lines.compactMap(\.number).max() ?? 0).count, 1)
        hasMarks = lines.contains { $0.mark != nil }
    }

    func rows(shown: Int, ink: Color?) -> [CodeRowModel] {
        if let cache = rowCache, cache.shown == shown, cache.generation == generation { return cache.rows }
        let rows = (0..<shown).map { i in
            CodeRowModel(id: i, line: lines[i], text: i < colours.count ? colours[i] : nil, gutterDigits: gutterDigits,
                         hasMark: hasMarks, reserve: i == 0 ? 52 : 0, ink: ink)
        }
        rowCache = (shown, generation, rows)
        return rows
    }
}

/// The items of a session's code blocks by `<blockID>-<part>`. Lives in `SessionUIStore`, so a row that scrolls away
/// and back, or a session switch, neither rebuilds the lines nor highlights them again.
@MainActor
final class CodeBlockStore {
    private var items: [String: CodeBlockItem] = [:]
    private var memos: [String: (key: Int, value: Any)] = [:]

    func item(id: String, fingerprint: Int, build: () -> (lines: [CodeLine], plan: [OutputSection])) -> CodeBlockItem {
        if let existing = items[id], existing.fingerprint == fingerprint { return existing }
        let made = build()
        let item = CodeBlockItem(fingerprint: fingerprint, lines: made.lines, plan: made.plan)
        items[id] = item
        return item
    }

    /// A value derived from a tool block (its split output, fingerprints), rebuilt only when `key` changes.
    func memo<T>(_ id: String, key: Int, build: () -> T) -> T {
        if let hit = memos[id], hit.key == key, let value = hit.value as? T { return value }
        let value = build()
        memos[id] = (key, value)
        return value
    }

    /// Forgets the items and memos of blocks that are no longer in the transcript. Keys are `<blockID>-<part>` and
    /// parts hold no hyphen.
    @discardableResult func prune(keepingBlockIDs keep: Set<String>) -> Int {
        func block(_ key: String) -> String { key.lastIndex(of: "-").map { String(key[..<$0]) } ?? key }
        items = items.filter { keep.contains(block($0.key)) }
        memos = memos.filter { keep.contains(block($0.key)) }
        return count
    }

    var count: Int { items.count + memos.count }
}

/// What the code blocks of one session share: which are expanded, and their cached items.
struct CodeBlockState {
    let expanded: Binding<[String: Bool]>
    let store: CodeBlockStore

    @MainActor static func detached() -> CodeBlockState { CodeBlockState(expanded: .constant([:]), store: CodeBlockStore()) }

    @MainActor func binding(_ key: String) -> Binding<Bool> {
        let expanded = expanded
        return Binding(get: { expanded.wrappedValue[key] ?? false }, set: { expanded.wrappedValue[key] = $0 })
    }
}

/// A code block in the chat: line-numbered gutter, syntax colours (computed off the main actor, only for the lines
/// shown), a Copy button, and a collapse to ``collapsedLines`` lines behind an eye toggle in the container's top-right
/// corner. Only the shown lines are built, at most ``maxRows``. The container is identified `code-<blockID>-<part>`,
/// the eye `code-toggle-<blockID>-<part>`, the button `code-copy-<blockID>-<part>`, the note's file link
/// `code-open-<blockID>-<part>`.
struct ChatCodeBlock: Component {
    static let collapsedLines = 6
    /// Rows built when expanded.
    static let maxRows = 500

    let blockID: String
    let part: String
    let expanded: Binding<Bool>
    let item: CodeBlockItem
    var ink: Color?
    var overflow: CodeOverflow = .count
    @State var tick = 0
    @Environment(\.colorScheme) var scheme
    @Environment(\.clipboard) var clipboard

    struct WorkKey: Equatable { var fingerprint: Int; var dark: Bool; var shown: Int }

    var content: some ElementGroup {
        let total = item.total
        let canCollapse = total > Self.collapsedLines
        let isOpen = expanded.wrappedValue
        let shown = canCollapse && !isOpen ? Self.collapsedLines : min(total, Self.maxRows)
        let rows = item.rows(shown: shown, ink: ink)
        let rest = total - shown
        let blockID = blockID, part = part, item = item, scheme = scheme
        let key = WorkKey(fingerprint: item.fingerprint, dark: scheme == .dark, shown: shown)
        let refresh = $tick
        let expanded = expanded, clipboard = clipboard
        VStack(alignment: .leading, spacing: 0) {
            ForEach(rows, id: \.id) { row in
                CodeRow(model: row)
            }
            if rest > 0 { note(rest: rest, total: total, firstHidden: item.lines[shown].number) }
        }
        .padding(inset(0, 4))
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.markdownCodeFill)
        .cornerRadius(Pixels(6))
        .overlay(alignment: .topTrailing) {
            HStack(spacing: Pixels(0)) {
                CodeCopyButton(id: "code-copy-\(blockID)-\(part)", clipboard: clipboard) { item.fullText }
                if canCollapse {
                    Button { expanded.wrappedValue.toggle() } label: {
                        Image(systemName: isOpen ? "eye.circle" : "eye.slash.circle").font(.system(size: 14))
                            .foregroundColor(.mutedInk).padding(Pixels(3))
                    }
                    .buttonStyle(.plain)
                    .help(isOpen ? "Show less" : "Show all")
                    .accessibilityLabel(isOpen ? "Show less" : "Show all \(total) lines")
                    .accessibilityIdentifier("code-toggle-\(blockID)-\(part)")
                }
            }
            .padding(Pixels(2))
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("code-\(blockID)-\(part)")
        .task(id: key) {
            if item.plan.isEmpty || (item.scheme == scheme && item.colours.count >= shown) { return }
            let texts = item.lines.prefix(shown).map(\.text)
            let plan = item.plan.compactMap { s -> OutputSection? in
                let r = s.lines.clamped(to: 0..<shown)
                return r.isEmpty ? nil : OutputSection(lines: r, language: s.language)
            }
            let computed = await CodeHighlight.compute(lines: Array(texts), plan: plan, scheme: scheme, tag: "\(blockID)-\(part)")
            guard !Task.isCancelled, let computed else { return }
            item.colours = computed
            item.scheme = scheme
            refresh.wrappedValue += 1
        }
    }

    @ElementBuilder
    private func note(rest: Int, total: Int, firstHidden: Int?) -> some ElementGroup {
        let id = "code-open-\(blockID)-\(part)"
        HStack(spacing: Pixels(6)) {
            switch overflow {
            case .count:
                Text(verbatim: "\(rest) more lines").font(size: 11).foregroundColor(.mutedInk)
            case .copyAll:
                Text(verbatim: "Copy to get all \(total) lines").font(size: 11).foregroundColor(.mutedInk)
            case .openFile(let open):
                Text(verbatim: "\(rest) more lines").font(size: 11).foregroundColor(.mutedInk)
                Button { open(firstHidden) } label: {
                    Text(verbatim: "Open file").font(size: 11).foregroundColor(.linkInk)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier(id)
            }
        }
        .padding(inset(8, 2))
    }
}

/// The Copy button: the clipboard gets the text asked for at the press, and the icon is a checkmark labelled "Copied"
/// for 1.5 s, as MetalUI's fence button does.
struct CodeCopyButton: Component {
    static let feedbackSeconds = 1.5
    enum Phase: CaseIterable { case idle, pressed, copied }

    let id: String
    let clipboard: Clipboard
    let text: () -> String
    @State private var presses = 0

    init(id: String, clipboard: Clipboard, text: @escaping () -> String) {
        self.id = id; self.clipboard = clipboard; self.text = text
    }

    var content: some ElementGroup {
        let id = id, clipboard = clipboard, text = text
        let copy = { if clipboard.write(text()) { presses += 1 } }
        Box().phaseAnimator(Phase.allCases, trigger: presses) { _, phase in
            let copied = phase != .idle
            Button { copy() } label: {
                Image(systemName: copied ? "checkmark" : "doc.on.doc").font(.system(size: 12)).foregroundColor(.mutedInk)
                    .padding(Pixels(4))
            }
            .buttonStyle(.plain)
            .help("Copy")
            .accessibilityLabel(copied ? "Copied" : "Copy")
            .accessibilityIdentifier(id)
        } animation: { phase in phase == .copied ? .linear(duration: Self.feedbackSeconds) : nil }
    }
}

struct CodeRowModel {
    var id: Int
    var line: CodeLine
    var text: AttributedString?
    var gutterDigits: Int
    var hasMark: Bool
    /// Space kept free at the end of the row for the buttons overlaid on the first one.
    var reserve: Float
    var ink: Color?
}

/// One line: gutter number, diff mark, code.
struct CodeRow: Component {
    let model: CodeRowModel

    var content: some ElementGroup {
        let model = model
        let line = model.line
        HStack(alignment: .top, spacing: Pixels(6)) {
            Text(verbatim: line.number.map(String.init) ?? " ").font(family: "Menlo", size: 11).foregroundColor(.mutedInk)
                .frame(width: Pixels(Float(model.gutterDigits) * 7), alignment: .trailing)
            if model.hasMark {
                Text(verbatim: line.mark ?? " ").font(family: "Menlo", size: 11).foregroundColor(.mutedInk)
            }
            code
            if model.reserve > 0 { Spacer().frame(width: Pixels(model.reserve), height: Pixels(1)) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(inset(8, 1))
        .background(line.tint ?? Color.clear)
    }

    @ElementBuilder
    private var code: some ElementGroup {
        if let text = model.text, !model.line.text.isEmpty {
            Text(text).font(family: "Menlo", size: 11)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else if let ink = model.ink {
            Text(verbatim: model.line.text.isEmpty ? " " : model.line.text).font(family: "Menlo", size: 11).foregroundColor(ink)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            Text(verbatim: model.line.text.isEmpty ? " " : model.line.text).font(family: "Menlo", size: 11)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
