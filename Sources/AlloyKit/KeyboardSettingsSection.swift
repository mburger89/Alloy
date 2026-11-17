import AlloyCore
import Foundation
import MetalUI

/// The keyboard part of Settings: every registry command with the shortcut it resolves to, a filter, clash flags and
/// the read-only built-in keys. Rows are recomputed only when the filter, the keymap revision, the registry or the
/// settings change (this component reads them in its body), never per frame; it exists only while Settings is open.
struct KeyboardSettingsSection: Component {
    let workspace: Workspace
    let center: CommandCenter
    @State var filter = ""
    @State var failure: String?
    @State var pending: Pending?

    /// A rebind waiting on "Reassign from <holder>?".
    struct Pending: Equatable {
        var id: String
        var chord: KeyChord
        var holder: String
        var holderTitle: String
    }

    /// Everything one command row shows; the row view replays unless this changes.
    struct RowModel: Equatable {
        var id: String
        var title: String
        var chordText: String
        var shortcut: KeyboardShortcut?
        var source: String
        var isCustom: Bool
        var conflict: String?
    }

    /// A read-only built-in key row.
    struct BuiltInModel: Equatable {
        var index: Int
        var title: String
        var chordText: String
        var condition: String?
    }

    var content: some ElementGroup {
        let workspace = workspace
        // Read here so the section re-evaluates when the keymap or the command set changes.
        let revision = center.registry.keymap.revision &+ center.registry.revision
        let overrides = workspace.settings.keybindings
        let groups = Self.groups(center: center, overrides: overrides, filter: filter, revision: revision)
        let builtIn = Self.builtInRows(center: center, filter: filter)
        let empty = groups.isEmpty && builtIn.isEmpty
        let pendingState = $pending
        let prompt = pending
        VStack(alignment: .leading, spacing: Pixels(8)) {
            Text("Keyboard").font(size: 12).foregroundColor(.mutedInk).accessibilityIdentifier("settings-keyboard-heading")
            HStack(spacing: Pixels(8)) {
                TextField("Filter shortcuts", text: $filter).accessibilityIdentifier("keyboard-filter")
                Button("Reset all") { resetAll() }.accessibilityIdentifier("keyboard-reset-all")
            }
            ForEach(groups, id: \.name) { group in
                Text(verbatim: group.name).font(size: 11).foregroundColor(.mutedInk)
                ForEach(group.rows, id: \.id) { row in
                    KeyboardCommandRow(model: row, onReset: { reset(row.id) },
                                       onRecord: { record(row.id, $0) }, onClear: { clear(row.id) }).equatable()
                }
            }
            if let prompt {
                HStack(spacing: Pixels(8)) {
                    Text(verbatim: "Reassign from \(prompt.holderTitle)?").font(size: 12)
                        .accessibilityIdentifier("keyboard-reassign-prompt")
                    Button("Reassign") { confirmReassign() }.accessibilityIdentifier("keyboard-reassign-confirm")
                    Button("Cancel") { pendingState.wrappedValue = nil }.accessibilityIdentifier("keyboard-reassign-cancel")
                }
            }
            if !builtIn.isEmpty {
                Text("Built-in").font(size: 11).foregroundColor(.mutedInk)
                ForEach(builtIn, id: \.index) { row in
                    KeyboardBuiltInRow(model: row).equatable()
                }
            }
            if empty {
                Text("No matching commands").font(size: 12).foregroundColor(.mutedInk).accessibilityIdentifier("keyboard-empty")
            }
            if let failure {
                Text(verbatim: failure).font(size: 11).foregroundColor(.errorInk).accessibilityIdentifier("keyboard-error")
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("settings-keyboard")
        .onChange(of: filter) { pendingState.wrappedValue = nil }
    }

    /// The command rows grouped by category in order of first appearance, filtered by title, id or chord text.
    @MainActor
    static func groups(center: CommandCenter, overrides: [String: String], filter: String,
                       revision: Int = 0) -> [(name: String, rows: [RowModel])] {
        _ = revision
        let registry = center.registry
        let platform = KeyboardShortcut.Platform.current
        let editor = KeybindingEditor(defaults: registry.commands.map { ($0.descriptor.id, $0.descriptor.shortcut) },
                                      primaryIsCmd: platform == .macOS)
        let clashes = ShortcutClashes(center: center, platform: platform)
        let needle = filter.trimmingCharacters(in: .whitespaces).lowercased()
        var order: [String] = []
        var byCategory: [String: [RowModel]] = [:]
        for command in registry.commands {
            let d = command.descriptor
            let chord = editor.effective(d.id, overrides: overrides)
            let text = chord.map { $0.shortcut.displayText } ?? "None"
            if !needle.isEmpty,
               !(d.title.lowercased().contains(needle) || d.id.lowercased().contains(needle) || text.lowercased().contains(needle)) {
                continue
            }
            let custom = editor.isCustom(d.id, overrides: overrides)
            let source = custom ? (chord == nil ? "unbound" : "custom") : "default"
            var note: String?
            if let chord {
                let found = clashes.clashes(for: chord, excluding: d.id, overrides: overrides)
                if !found.isEmpty { note = found.map(Self.describe).joined(separator: "; ") }
            }
            if byCategory[d.category.name] == nil { order.append(d.category.name) }
            byCategory[d.category.name, default: []].append(
                RowModel(id: d.id, title: d.title, chordText: text,
                         shortcut: chord.map { $0.shortcut(for: platform) }, source: source, isCustom: custom, conflict: note))
        }
        return order.map { ($0, byCategory[$0] ?? []) }
    }

    /// "Conflicts with <title>" for a command or hard claim; "<title> (<condition>)" for a soft one.
    static func describe(_ clash: ShortcutClash) -> String {
        if clash.kind == .codeViewSoft { return "\(clash.title) (\(clash.condition ?? "sometimes"))" }
        return "Conflicts with \(clash.title)"
    }

    @MainActor
    static func builtInRows(center: CommandCenter, filter: String) -> [BuiltInModel] {
        let platform = KeyboardShortcut.Platform.current
        let needle = filter.trimmingCharacters(in: .whitespaces).lowercased()
        return ShortcutClashes(center: center, platform: platform).builtInRows.enumerated().compactMap { n, claim in
            let text = claim.shortcut.displayText(for: platform)
            if !needle.isEmpty, !(claim.title.lowercased().contains(needle) || text.lowercased().contains(needle)) { return nil }
            return BuiltInModel(index: n, title: claim.title, chordText: text, condition: claim.isConditional ? claim.condition : nil)
        }
    }

    private func editor() -> KeybindingEditor {
        KeybindingEditor(defaults: center.registry.commands.map { ($0.descriptor.id, $0.descriptor.shortcut) },
                         primaryIsCmd: KeyboardShortcut.Platform.current == .macOS)
    }

    private func reset(_ id: String) {
        write(editor().resetting(id, overrides: workspace.settings.keybindings))
    }

    private func resetAll() {
        write(editor().resettingAll(overrides: workspace.settings.keybindings))
    }

    /// A recorded key: ignored when no chord names it or it is already the effective chord; a command holder opens the
    /// prompt; anything else (system, menu, code view clashes included) is saved at once and flagged by the row.
    private func record(_ id: String, _ shortcut: KeyboardShortcut) {
        guard let chord = KeyChord.chord(from: shortcut) else { return }
        let overrides = workspace.settings.keybindings
        let editor = editor()
        let primaryIsCmd = KeyboardShortcut.Platform.current == .macOS
        if let current = editor.effective(id, overrides: overrides),
           current.resolved(primaryIsCmd: primaryIsCmd) == chord.resolved(primaryIsCmd: primaryIsCmd) {
            return
        }
        if let holder = editor.holder(of: chord, excluding: id, overrides: overrides) {
            let title = center.registry.command(id: holder)?.descriptor.title ?? holder
            pending = Pending(id: id, chord: chord, holder: holder, holderTitle: title)
            return
        }
        pending = nil
        write(editor.binding(id, to: chord, overrides: overrides))
    }

    private func clear(_ id: String) {
        pending = nil
        write(editor().clearing(id, overrides: workspace.settings.keybindings))
    }

    private func confirmReassign() {
        guard let p = pending else { return }
        pending = nil
        write(editor().reassigning(p.chord, to: p.id, from: p.holder, overrides: workspace.settings.keybindings))
    }

    /// One settings write; on failure nothing is applied and the error shows in the section.
    private func write(_ overrides: [String: String]) {
        var s = workspace.settings
        s.keybindings = overrides
        do { try workspace.updateSettings(s); failure = nil } catch { failure = "Could not save: \(error.localizedDescription)" }
    }
}

/// One command's row: title, its clash note, the effective chord, where it comes from, and Reset when custom.
struct KeyboardCommandRow: Component, Equatable {
    let model: KeyboardSettingsSection.RowModel
    let onReset: @MainActor () -> Void
    let onRecord: @MainActor (KeyboardShortcut) -> Void
    let onClear: @MainActor () -> Void

    nonisolated static func == (a: Self, b: Self) -> Bool { a.model == b.model }

    var content: some ElementGroup {
        let model = model, onReset = onReset, onRecord = onRecord, onClear = onClear
        HStack(spacing: Pixels(8)) {
            VStack(alignment: .leading, spacing: Pixels(2)) {
                Text(verbatim: model.title).font(size: 13)
                if let note = model.conflict {
                    Text(verbatim: note).font(size: 11).foregroundColor(.warningInk)
                        .accessibilityIdentifier("keyboard-conflict-\(model.id)")
                }
            }
            Spacer()
            Text(verbatim: model.source).font(size: 11).foregroundColor(.mutedInk)
            HStack(spacing: Pixels(0)) {
                ShortcutRecorder(model.shortcut, onRecord: onRecord, onClear: onClear, onCancel: {})
            }
            .accessibilityIdentifier("keyboard-chord-\(model.id)")
            if model.isCustom {
                Button("Reset") { onReset() }.accessibilityIdentifier("keyboard-reset-\(model.id)")
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("keyboard-row-\(model.id)")
    }
}

/// One read-only built-in key (the code view's own keys and Alloy's in-place keys).
struct KeyboardBuiltInRow: Component, Equatable {
    let model: KeyboardSettingsSection.BuiltInModel

    nonisolated static func == (a: Self, b: Self) -> Bool { a.model == b.model }

    var content: some ElementGroup {
        let model = model
        HStack(spacing: Pixels(8)) {
            Text(verbatim: model.condition.map { "\(model.title) (\($0))" } ?? model.title).font(size: 12)
            Spacer()
            Text(verbatim: model.chordText).font(size: 12).foregroundColor(.mutedInk)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("keyboard-builtin-\(model.index)")
    }
}
