import enum AlloyCore.TerminalCursorStyle
import MetalUI
import MetalUITerminal

/// What a focused terminal lets through to the app (spec "Calls settled up front" 2 and 3) and how Alloy's cursor
/// settings map to MetalUI's. Pure values, no state.
enum TerminalKeys {
    /// The shortcuts that skip the terminal's key capture and still reach Alloy's menus and global keys. Everything
    /// else (Ctrl-letters, Alt keys, function keys) goes to the program. On Apple platforms the app chords are
    /// command chords; elsewhere Ctrl belongs to the program, so copy, paste, find, select-all, new tab and close tab
    /// take primary+Shift (the Linux terminal convention) while the backtick chords stay Ctrl.
    static func exceptions(platform: KeyboardShortcut.Platform = .current) -> [KeyboardShortcut] {
        let primary = platform.primaryModifiers
        let apple = platform == .macOS
        let terminalPrimary: EventModifiers = apple ? primary : primary.union(.shift)
        func key(_ c: Character, _ mods: EventModifiers) -> KeyboardShortcut { KeyboardShortcut(KeyEquivalent(c), modifiers: mods) }
        var list: [KeyboardShortcut] = [
            key("`", .control), key("`", [.control, .shift]),
            key("\\", primary), key("\\", [primary, .option]),
            key("p", terminalPrimary), key("p", [primary, .shift]),
            key("1", [.control, .command]), key("2", [.control, .command]),
            key(",", primary), key("q", terminalPrimary),
            KeyboardShortcut(.tab, modifiers: .control), KeyboardShortcut(.tab, modifiers: [.control, .shift]),
        ]
        for c: Character in ["w", "t", "c", "v", "f", "a"] { list.append(key(c, terminalPrimary)) }
        // Clear scrollback is command-K; Ctrl-K belongs to the shell, so elsewhere it is primary+Shift too.
        list.append(key("k", terminalPrimary))
        for n in 1...9 { list.append(key(Character(String(n)), primary)) }
        return list
    }

    /// MetalUI's cursor style for Alloy's setting. `blink` is the `cursorBlink` setting: it makes the style ask to blink.
    static func cursorStyle(_ style: TerminalCursorStyle, blink: Bool) -> MetalUITerminal.TerminalCursorStyle {
        let shape: MetalUITerminal.TerminalCursorStyle.Shape
        switch style {
        case .block: shape = .block
        case .bar: shape = .bar
        case .underline: shape = .underline
        }
        return MetalUITerminal.TerminalCursorStyle(shape: shape, blinking: blink)
    }
}
