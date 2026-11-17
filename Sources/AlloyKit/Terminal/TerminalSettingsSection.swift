import AlloyCore
import Foundation
import MetalUI

/// The terminal part of Settings. Every control writes through `workspace.updateSettings` at once; the text and number
/// fields commit on submit, and numbers clamp to their range.
struct TerminalSettingsSection: Component {
    let workspace: Workspace
    @State var shell = ""
    @State var fontSize = ""
    @State var scrollback = ""
    @State var loaded = false
    @State var failure: String?

    var content: some ElementGroup {
        VStack(alignment: .leading, spacing: Pixels(8)) {
            Text("Terminal").font(size: 12).foregroundColor(.mutedInk).accessibilityIdentifier("settings-terminal-heading")
            TextField("Login shell", text: $shell)
                .onSubmit { commitShell() }
                .accessibilityIdentifier("settings-terminal-shell")
            TextField("Editor size", text: $fontSize)
                .onSubmit { commitFontSize() }
                .accessibilityIdentifier("settings-terminal-font-size")
            TextField("Scrollback lines", text: $scrollback)
                .onSubmit { commitScrollback() }
                .accessibilityIdentifier("settings-terminal-scrollback")
            Toggle(isOn: flag(\.optionAsMeta)) { Text("Option as Meta").font(size: 13) }
                .accessibilityIdentifier("settings-terminal-option-meta")
            Picker("Cursor", selection: cursorBinding) {
                Text("Block").tag(TerminalCursorStyle.block)
                Text("Bar").tag(TerminalCursorStyle.bar)
                Text("Underline").tag(TerminalCursorStyle.underline)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .accessibilityIdentifier("settings-terminal-cursor")
            Toggle(isOn: flag(\.cursorBlink)) { Text("Blinking cursor").font(size: 13) }
                .accessibilityIdentifier("settings-terminal-blink")
            Toggle(isOn: flag(\.confirmMultilinePaste)) { Text("Confirm multi-line paste").font(size: 13) }
                .accessibilityIdentifier("settings-terminal-paste-confirm")
            Text("Empty shell uses your login shell; empty size follows the editor.").font(size: 11).foregroundColor(.mutedInk)
            if let failure {
                Text(verbatim: failure).font(size: 11).foregroundColor(.errorInk).accessibilityIdentifier("settings-terminal-error")
            }
        }
        .onAppear { load() }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("settings-terminal-section")
    }

    private func load() {
        guard !loaded else { return }
        loaded = true
        let t = workspace.settings.terminal
        shell = t.shellPath ?? ""
        fontSize = t.fontSize.map { Self.format($0) } ?? ""
        scrollback = String(t.scrollbackLines)
    }

    private static func format(_ v: Double) -> String { v == v.rounded() ? String(Int(v)) : String(v) }

    private func flag(_ key: WritableKeyPath<TerminalSettings, Bool>) -> Binding<Bool> {
        let workspace = workspace
        return Binding(get: { workspace.settings.terminal[keyPath: key] },
                       set: { value in update { $0[keyPath: key] = value } })
    }

    private var cursorBinding: Binding<TerminalCursorStyle> {
        let workspace = workspace
        return Binding(get: { workspace.settings.terminal.cursorStyle }, set: { v in update { $0.cursorStyle = v } })
    }

    private func commitShell() {
        update { $0.shellPath = shell }
        shell = workspace.settings.terminal.shellPath ?? ""
    }

    private func commitFontSize() {
        let text = fontSize.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { update { $0.fontSize = nil } } else if let v = Double(text), v.isFinite {
            update { $0 = TerminalSettings(shellPath: $0.shellPath, fontSize: v, scrollbackLines: $0.scrollbackLines,
                                           optionAsMeta: $0.optionAsMeta, cursorStyle: $0.cursorStyle,
                                           cursorBlink: $0.cursorBlink, confirmMultilinePaste: $0.confirmMultilinePaste) }
        }
        fontSize = workspace.settings.terminal.fontSize.map { Self.format($0) } ?? ""
    }

    private func commitScrollback() {
        if let v = Int(scrollback.trimmingCharacters(in: .whitespacesAndNewlines)) {
            update { $0 = TerminalSettings(shellPath: $0.shellPath, fontSize: $0.fontSize, scrollbackLines: v,
                                           optionAsMeta: $0.optionAsMeta, cursorStyle: $0.cursorStyle,
                                           cursorBlink: $0.cursorBlink, confirmMultilinePaste: $0.confirmMultilinePaste) }
        }
        scrollback = String(workspace.settings.terminal.scrollbackLines)
    }

    /// Edits a copy of the terminal settings and saves; the stored values are re-normalised through the initializer.
    private func update(_ edit: (inout TerminalSettings) -> Void) {
        var s = workspace.settings
        edit(&s.terminal)
        let t = s.terminal
        s.terminal = TerminalSettings(shellPath: t.shellPath, fontSize: t.fontSize, scrollbackLines: t.scrollbackLines,
                                      optionAsMeta: t.optionAsMeta, cursorStyle: t.cursorStyle, cursorBlink: t.cursorBlink,
                                      confirmMultilinePaste: t.confirmMultilinePaste)
        do { try workspace.updateSettings(s); failure = nil } catch { failure = "Could not save: \(error.localizedDescription)" }
    }
}
