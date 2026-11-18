import MetalUITerminal

/// Decides whether a paste needs a confirmation: more than one line into a program that has not enabled bracketed paste.
enum TerminalPasteGuard {
    /// Lines in `text`. CRLF, CR and LF each count as one break; one trailing break is not counted, so "ls\n" is one line.
    static func lineCount(_ text: String) -> Int {
        guard !text.isEmpty else { return 0 }
        var breaks = 0
        var pendingCR = false
        var endsWithBreak = false
        for byte in text.utf8 {
            if byte == 0x0A {
                if !pendingCR { breaks += 1 }
                pendingCR = false
                endsWithBreak = true
            } else if byte == 0x0D {
                breaks += 1
                pendingCR = true
                endsWithBreak = true
            } else {
                pendingCR = false
                endsWithBreak = false
            }
        }
        return breaks + 1 - (endsWithBreak ? 1 : 0)
    }

    static func needsConfirm(_ text: String, modes: TerminalModes, enabled: Bool) -> Bool {
        enabled && !modes.bracketedPaste && lineCount(text) > 1
    }
}
