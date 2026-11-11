import Foundation

/// What Alloy does with a message that starts with `/`.
public enum SlashRoute: Equatable, Sendable {
    /// Sent to the CLI unchanged.
    case passThrough
    case setModel(String)
    case showModelPicker
    case setMode(PermissionMode)
    case localHelp
    /// `/fork [name]`: a new session from this conversation.
    case fork(name: String?)
    /// `/theme [description]`: a new theme-making session.
    case theme(description: String?)
}

public enum SlashCommands {
    /// Routes on the trimmed text. Only text starting with `/` is a command; its name runs up to the first whitespace.
    public static func route(_ text: String) -> SlashRoute {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("/") else { return .passThrough }
        let body = trimmed.dropFirst()
        let name = body.prefix { !$0.isWhitespace }
        let argument = body.dropFirst(name.count).trimmingCharacters(in: .whitespacesAndNewlines)
        switch name {
        case "model": return argument.isEmpty ? .showModelPicker : .setModel(argument)
        // `/plan <prompt>` starts a plan with a prompt in the CLI; Alloy only owns the bare switch.
        case "plan": return argument.isEmpty ? .setMode(.plan) : .passThrough
        case "help": return .localHelp
        case "fork": return .fork(name: argument.isEmpty ? nil : argument)
        case "theme": return .theme(description: argument.isEmpty ? nil : argument)
        default: return .passThrough
        }
    }

    /// The text of the local `/help` notice: one `name — description` line per command.
    static func helpText(_ commands: [SlashCommandInfo]) -> String {
        guard !commands.isEmpty else { return "No slash commands are available yet." }
        return commands.map { c in
            var line = "/\(c.name)"
            if let hint = c.argumentHint, !hint.isEmpty { line += " \(hint)" }
            return c.description.isEmpty ? line : "\(line) — \(c.description)"
        }.joined(separator: "\n")
    }
}
