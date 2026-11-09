import AppKit
import Carbon.HIToolbox
import CoreGraphics
import Darwin

public enum Input {
    public static func activate(pid: pid_t) async {
        NSRunningApplication(processIdentifier: pid)?.activate()
        try? await Task.sleep(for: .milliseconds(300))
    }

    /// Posts keyDown/keyUp for a character via its unicode string; returns mach_absolute_time at post.
    public static func typeKey(_ char: Character, to pid: pid_t) -> UInt64 {
        let src = CGEventSource(stateID: .hidSystemState)
        let units = Array(String(char).utf16)
        let down = CGEvent(keyboardEventSource: src, virtualKey: keyCode(for: char) ?? 0, keyDown: true)
        let up = CGEvent(keyboardEventSource: src, virtualKey: keyCode(for: char) ?? 0, keyDown: false)
        down?.keyboardSetUnicodeString(stringLength: units.count, unicodeString: units)
        up?.keyboardSetUnicodeString(stringLength: units.count, unicodeString: units)
        let t = mach_absolute_time()
        down?.postToPid(pid)
        up?.postToPid(pid)
        return t
    }

    /// Scrolls by whole lines (positive = up); returns mach_absolute_time at post.
    /// With `at` (global top-left display coordinates, e.g. the window centre) the event is posted to the session
    /// event tap at that location, so the window server routes it to the window under that point (the cursor is
    /// not moved). Events posted with `postToPid` carry no target window and do not scroll AppKit scroll views
    /// (verified on the fixture). The target window must be frontmost and unobscured at `at`.
    public static func scroll(lines: Int32, to pid: pid_t, at point: CGPoint? = nil) -> UInt64 {
        let ev = CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 1,
                         wheel1: lines, wheel2: 0, wheel3: 0)
        let t = mach_absolute_time()
        if let point {
            ev?.location = point
            ev?.post(tap: .cgSessionEventTap)
        } else {
            ev?.postToPid(pid)
        }
        return t
    }

    /// Posts one left click at `point` (global top-left coordinates) through the session event tap; the target
    /// window must be frontmost and unobscured there.
    public static func click(at point: CGPoint) {
        let src = CGEventSource(stateID: .hidSystemState)
        for type in [CGEventType.leftMouseDown, .leftMouseUp] {
            CGEvent(mouseEventSource: src, mouseType: type, mouseCursorPosition: point, mouseButton: .left)?
                .post(tap: .cgSessionEventTap)
        }
    }

    /// Posts Cmd+Down (caret to end of document) to the app.
    public static func moveCaretToEnd(to pid: pid_t) {
        let src = CGEventSource(stateID: .hidSystemState)
        for down in [true, false] {
            let ev = CGEvent(keyboardEventSource: src, virtualKey: CGKeyCode(kVK_DownArrow), keyDown: down)
            ev?.flags = .maskCommand
            ev?.postToPid(pid)
        }
    }

    private static func keyCode(for c: Character) -> CGKeyCode? {
        let map: [Character: Int] = ["a": kVK_ANSI_A, "b": kVK_ANSI_B, "c": kVK_ANSI_C, "d": kVK_ANSI_D, "e": kVK_ANSI_E,
            "f": kVK_ANSI_F, "g": kVK_ANSI_G, "h": kVK_ANSI_H, "i": kVK_ANSI_I, "j": kVK_ANSI_J, "k": kVK_ANSI_K,
            "l": kVK_ANSI_L, "m": kVK_ANSI_M, "n": kVK_ANSI_N, "o": kVK_ANSI_O, "p": kVK_ANSI_P, "q": kVK_ANSI_Q,
            "r": kVK_ANSI_R, "s": kVK_ANSI_S, "t": kVK_ANSI_T, "u": kVK_ANSI_U, "v": kVK_ANSI_V, "w": kVK_ANSI_W,
            "x": kVK_ANSI_X, "y": kVK_ANSI_Y, "z": kVK_ANSI_Z, " ": kVK_Space]
        return map[Character(c.lowercased())].map { CGKeyCode($0) }
    }
}
