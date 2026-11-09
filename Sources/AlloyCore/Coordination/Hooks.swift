import Foundation

/// Which hook event a request or reply belongs to.
public enum HookEvent: String, Sendable, Equatable {
    case preToolUse = "PreToolUse"
    case postToolUse = "PostToolUse"

    /// The route the CLI posts this event to.
    public var path: String {
        switch self {
        case .preToolUse: "/hooks/pre-tool-use"
        case .postToolUse: "/hooks/post-tool-use"
        }
    }
}

/// A PreToolUse or PostToolUse http hook body, decoded from the CLI (shape from the real captures).
public struct HookRequest: Sendable {
    public let event: HookEvent
    /// Exactly as the CLI sent it.
    public let toolName: String
    public let toolUseID: String
    public let toolInput: JSONValue
    /// PostToolUse only.
    public let toolResponse: JSONValue?
    public let cliSessionID: String

    public init(event: HookEvent, toolName: String, toolUseID: String, toolInput: JSONValue,
                toolResponse: JSONValue? = nil, cliSessionID: String) {
        self.event = event
        self.toolName = toolName
        self.toolUseID = toolUseID
        self.toolInput = toolInput
        self.toolResponse = toolResponse
        self.cliSessionID = cliSessionID
    }

    /// Nil when the body is not a tool hook with the fields Alloy needs.
    public init?(body: Data) {
        guard let json = JSONValue.parse(body), case .object = json,
              let name = json["hook_event_name"]?.stringValue, let event = HookEvent(rawValue: name),
              let tool = json["tool_name"]?.stringValue,
              let useID = json["tool_use_id"]?.stringValue,
              let input = json["tool_input"], case .object = input,
              let sid = json["session_id"]?.stringValue else { return nil }
        self.init(event: event, toolName: tool, toolUseID: useID, toolInput: input,
                  toolResponse: json["tool_response"], cliSessionID: sid)
    }
}

/// What a hook may say back: context for the model, and nothing else. Hooks never decide permissions.
public struct HookReply: Sendable, Equatable {
    public var additionalContext: String?
    /// The CLI inlines context only up to 10,000 characters; longer text becomes a file the model must read.
    public static let maxContextCharacters = 9_500
    public init(additionalContext: String? = nil) { self.additionalContext = additionalContext }

    /// `{"hookSpecificOutput":{"hookEventName":…,"additionalContext":…}}`, or `{}` without context.
    public func json(for event: HookEvent) -> Data {
        guard var text = additionalContext, !text.isEmpty else { return Data("{}".utf8) }
        if text.count > Self.maxContextCharacters { text = String(text.prefix(Self.maxContextCharacters - 1)) + "…" }
        let object: [String: Any] = ["hookSpecificOutput": ["hookEventName": event.rawValue, "additionalContext": text]]
        return (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes]))
            ?? Data("{}".utf8)
    }

    public static let empty = Data("{}".utf8)
}

public enum Hooks {
    /// Edit tools the hooks watch.
    public static let matcher = "Edit|MultiEdit|Write|NotebookEdit"
    /// Seconds the CLI waits for a hook before it proceeds without it.
    public static let timeoutSeconds = 3

    /// The URL of one hook route on the same server as `serverURL`.
    public static func url(for event: HookEvent, serverURL: URL) -> URL {
        var parts = URLComponents(url: serverURL, resolvingAgainstBaseURL: false) ?? URLComponents()
        parts.path = event.path
        parts.query = nil
        return parts.url ?? serverURL
    }

    /// The `--settings` value: a `hooks` object only. The CLI merges it with the user's own settings.
    public static func settingsJSON(url serverURL: URL, token: String) -> String {
        func entry(_ event: HookEvent) -> [[String: Any]] {
            [["matcher": matcher,
              "hooks": [["type": "http", "url": url(for: event, serverURL: serverURL).absoluteString,
                         "headers": ["Authorization": "Bearer " + token],
                         "timeout": timeoutSeconds] as [String: Any]]]]
        }
        let object: [String: Any] = ["hooks": [HookEvent.preToolUse.rawValue: entry(.preToolUse),
                                               HookEvent.postToolUse.rawValue: entry(.postToolUse)]]
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes]),
              let text = String(data: data, encoding: .utf8) else { return "{\"hooks\":{}}" }
        return text
    }
}
