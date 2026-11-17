import AlloyLSP
import Foundation
import MetalUI
import Observation

/// One row of the completion popup.
struct CompletionRow: Equatable {
    /// The index of the item in the scheduler's list.
    var index: Int
    var label: String
    var detail: String?
    var kindGlyph: String

    /// A one-letter mark for an LSP `CompletionItemKind`.
    static func glyph(for kind: Int?) -> String {
        switch kind {
        case 1: "t"
        case 2: "m"
        case 3: "f"
        case 4: "c"
        case 5: "f"
        case 6: "v"
        case 7: "C"
        case 8: "I"
        case 9: "M"
        case 10: "p"
        case 11: "u"
        case 12: "="
        case 13: "E"
        case 14: "k"
        case 15: "s"
        case 16: "#"
        case 17: "F"
        case 18: "r"
        case 19: "D"
        case 20: "e"
        case 21: "c"
        case 22: "S"
        case 23: "!"
        case 24: "o"
        case 25: "T"
        default: "·"
        }
    }
}

/// One row of the code action list.
struct ActionRow: Equatable {
    /// The index of the action in the scheduler's list.
    var index: Int
    var title: String
    /// Why the action cannot run, when the server disabled it.
    var disabledReason: String?
    var isPreferred: Bool
}

/// The signature line above the completion list: the label with the active parameter's UTF-8 range in it.
struct SignatureStrip: Equatable {
    var label: String
    /// UTF-8 offsets into `label`; nil when the server named no active parameter.
    var activeParameter: Range<Int>?
    /// The shown overload and how many there are.
    var index: Int
    var count: Int

    /// The label split around the active parameter: before, active, after.
    var parts: (String, String, String) {
        let bytes = Array(label.utf8)
        guard let r = activeParameter, r.lowerBound >= 0, r.upperBound <= bytes.count, !r.isEmpty else { return (label, "", "") }
        func s(_ a: Int, _ b: Int) -> String { String(decoding: bytes[a..<b], as: UTF8.self) }
        return (s(0, r.lowerBound), s(r.lowerBound, r.upperBound), s(r.upperBound, bytes.count))
    }
}

/// What the view's one suggestion overlay shows. Only the overlay's content closure and its presented binding read it. It is
/// written when the visible rows or the selection change, never when a request starts.
@MainActor @Observable
final class IntelligenceOverlayModel {
    enum Content: Equatable { case none, completion, actions }

    private(set) var content: Content = .none
    private(set) var rows: [CompletionRow] = []
    private(set) var actions: [ActionRow] = []
    private(set) var selected = 0
    private(set) var doc: String?
    private(set) var signature: SignatureStrip?
    /// The parsed Markdown of the open popup's documentation, kept across the overlay's rebuilds.
    @ObservationIgnored let markdownCache = MarkdownCache()
    /// The most rows the popup shows.
    nonisolated static let rowCap = 50
    /// The most documentation lines shown.
    nonisolated static let docLines = 12

    var isPresented: Bool {
        (content == .completion && !rows.isEmpty) || (content == .actions && !actions.isEmpty) || signature != nil
    }

    /// Shows `rows` for `content`, keeping the selection on the same item when it is still there. Writes only a change.
    func show(_ content: Content, rows: [CompletionRow], keepSelectionOn index: Int? = nil) {
        let rows = Array(rows.prefix(Self.rowCap))
        var selection = 0
        if let index, let at = rows.firstIndex(where: { $0.index == index }) { selection = at }
        if self.content != content { self.content = content }
        if self.rows != rows { self.rows = rows }
        if selected != selection { selected = selection }
    }

    /// Shows the code action list (the selection starts on the first row).
    func showActions(_ actions: [ActionRow]) {
        let actions = Array(actions.prefix(Self.rowCap))
        if !rows.isEmpty { rows = [] }
        if doc != nil { doc = nil }
        if content != .actions { content = .actions }
        if self.actions != actions { self.actions = actions }
        if selected != 0 { selected = 0 }
    }

    func select(_ position: Int) {
        let count = content == .actions ? actions.count : rows.count
        guard count > 0 else { return }
        let clamped = min(max(position, 0), count - 1)
        if selected != clamped { selected = clamped }
    }

    func setDoc(_ text: String?) {
        let cut = text.map { Self.cut($0) }
        if doc != cut { doc = cut }
    }

    /// The item index of the selected row.
    var selectedItem: Int? { rows.indices.contains(selected) ? rows[selected].index : nil }

    func setSignature(_ strip: SignatureStrip?) {
        if signature != strip { signature = strip }
    }

    /// Clears the list; the signature strip stays (see ``setSignature(_:)``).
    func clear() {
        if content != .none { content = .none }
        if !rows.isEmpty { rows = [] }
        if !actions.isEmpty { actions = [] }
        if selected != 0 { selected = 0 }
        if doc != nil { doc = nil }
    }

    static func cut(_ text: String) -> String {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        guard lines.count > docLines else { return text }
        return lines.prefix(docLines).joined(separator: "\n")
    }
}
