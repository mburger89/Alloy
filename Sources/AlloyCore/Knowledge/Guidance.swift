import Foundation

/// What every Alloy session is told about the shared notes, appended to the system prompt at launch.
public enum Guidance {
    public static let text = "This project is shared with other sessions through Alloy. Before reading a file, call mcp__alloy__notes_lookup with its path. If the notes say its text can be served, call mcp__alloy__notes_read for just the lines you need instead of reading the file. After reading a file you will rely on, call mcp__alloy__notes_write with the note in `text` (one to three sentences on what the file does and anything surprising) and the file in `path`. Treat notes marked [stale] as hints only: the file changed after they were written. If the notes tools fail, read files normally. Before a large edit, call mcp__alloy__sessions_changes to see what other sessions changed. For multi-step work on part of a file, call mcp__alloy__claim_region first and mcp__alloy__release_region when you are done; claims are advisory. To tell another session something, call mcp__alloy__send_message with its name."

    public static let notesToolNames = ["mcp__alloy__notes_lookup", "mcp__alloy__notes_read", "mcp__alloy__notes_write"]
    public static let coordinationToolNames = ["mcp__alloy__sessions_changes", "mcp__alloy__send_message",
                                               "mcp__alloy__claim_region", "mcp__alloy__release_region"]
    /// The only tools Alloy pre-approves, each named exactly (never a wildcard).
    public static let alloyToolNames = notesToolNames + coordinationToolNames
}
