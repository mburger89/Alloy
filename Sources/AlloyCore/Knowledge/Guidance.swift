import Foundation

/// What every Alloy session is told about the shared notes, appended to the system prompt at launch.
public enum Guidance {
    public static let text = "This project is shared with other sessions through Alloy. Before reading a file, call mcp__alloy__notes_lookup with its path. If the notes say its text can be served, call mcp__alloy__notes_read for just the lines you need instead of reading the file. After reading a file you will rely on, call mcp__alloy__notes_write with a one-to-three-sentence summary of what it does and anything surprising. Treat notes marked [stale] as hints only: the file changed after they were written. If the notes tools fail, read files normally."

    /// The only tools Alloy pre-approves.
    public static let notesToolNames = ["mcp__alloy__notes_lookup", "mcp__alloy__notes_read", "mcp__alloy__notes_write"]
}
