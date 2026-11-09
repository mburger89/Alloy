import Foundation

public enum ToolKind: String, Sendable, CaseIterable {
    case read, search, shell, edit, write, web, subagent, todo, question, plan, mcp, other

    public static func classify(_ toolName: String) -> ToolKind {
        if toolName.hasPrefix("mcp__") { return .mcp }
        switch toolName {
        case "Read", "NotebookRead": return .read
        case "Grep", "Glob", "LS": return .search
        case "Bash", "BashOutput", "KillShell": return .shell
        case "Edit", "MultiEdit", "NotebookEdit": return .edit
        case "Write": return .write
        case "WebFetch", "WebSearch": return .web
        case "Agent", "Task": return .subagent
        case "TodoWrite": return .todo
        case "AskUserQuestion": return .question
        case "ExitPlanMode": return .plan
        default: return .other
        }
    }
}

public enum ToolSummary {
    /// One-line description of a tool call. Paths inside `projectRoot` are made relative; others stay absolute.
    /// `result` is the CLI's `tool_use_result`; when given, Read, Grep and Glob add their line, match and file counts.
    public static func line(toolName: String, input: JSONValue, projectRoot: URL, result: JSONValue? = nil) -> String {
        func str(_ key: String) -> String? {
            guard let s = input[key]?.stringValue, !s.isEmpty else { return nil }
            return s
        }
        if toolName.hasPrefix("mcp__") {
            let parts = toolName.dropFirst("mcp__".count).components(separatedBy: "__")
            guard parts.count >= 2, !parts[0].isEmpty else { return toolName }
            return "\(parts[0]) \u{00B7} \(parts.dropFirst().joined(separator: "__"))"
        }
        switch toolName {
        case "Read":
            guard let path = str("file_path").map({ relativePath($0, root: projectRoot) }) else { return toolName }
            if let n = result?["file"]?["numLines"]?.intValue { return "\(path) \u{00B7} \(count(n, "line"))" }
            return path
        case "Edit", "Write":
            return str("file_path").map { relativePath($0, root: projectRoot) } ?? toolName
        case "Bash":
            return str("command").map { String($0.prefix(120)) } ?? toolName
        case "Grep":
            guard let pattern = str("pattern") else { return toolName }
            if let result {
                if let n = result["numMatches"]?.intValue { return "\"\(pattern)\" \u{00B7} \(count(n, "match", plural: "matches"))" }
                if result["mode"]?.stringValue == "content", let n = result["numLines"]?.intValue {
                    return "\"\(pattern)\" \u{00B7} \(count(n, "match", plural: "matches"))"
                }
                if let n = result["numFiles"]?.intValue { return "\"\(pattern)\" \u{00B7} \(count(n, "file"))" }
            }
            if let path = str("path") { return "\(pattern) in \(relativePath(path, root: projectRoot))" }
            return pattern
        case "Glob":
            guard let pattern = str("pattern") else { return toolName }
            if let n = result?["numFiles"]?.intValue { return "\(pattern) \u{00B7} \(count(n, "file"))" }
            return pattern
        case "WebFetch": return str("url") ?? toolName
        case "WebSearch": return str("query") ?? toolName
        case "Agent": return str("description") ?? toolName
        default: return toolName
        }
    }

    private static func count(_ n: Int, _ noun: String, plural: String? = nil) -> String {
        "\(n) \(n == 1 ? noun : (plural ?? noun + "s"))"
    }

    public static func relativePath(_ path: String, root: URL) -> String {
        func norm(_ p: String) -> String {
            var s = URL(fileURLWithPath: p).standardizedFileURL.path
            if s.hasPrefix("/private/") { s = String(s.dropFirst("/private".count)) }
            return s
        }
        let r = norm(root.path)
        let p = norm(path)
        let prefix = r.hasSuffix("/") ? r : r + "/"
        if p.hasPrefix(prefix) { return String(p.dropFirst(prefix.count)) }
        return path
    }
}
