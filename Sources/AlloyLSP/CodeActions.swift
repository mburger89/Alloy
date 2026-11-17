import AlloyCore
import Foundation
import MetalUICodeBuffer

/// A command a code action runs on its server through `workspace/executeCommand`.
public struct CodeActionCommand: Sendable, Equatable {
    public var command: String
    public var arguments: [JSONValue]

    public init(command: String, arguments: [JSONValue] = []) {
        self.command = command
        self.arguments = arguments
    }
}

/// One code action (or bare command) a server offered.
public struct CodeActionItem: Sendable, Equatable {
    /// The server's own title.
    public var title: String
    public var kind: String?
    public var isPreferred: Bool
    /// Set when the server marked the action `disabled`: why it cannot run.
    public var disabledReason: String?
    /// The inline `WorkspaceEdit`; nil when the action carries only `data` (see `resolveCodeAction`) or a command.
    public var edit: JSONValue?
    public var command: CodeActionCommand?
    public var data: JSONValue?
    /// The diagnostics the server says the action fixes.
    public var diagnostics: [JSONValue]
    public var serverID: String
    public var serverName: String
    public var role: ServerRole
    /// The action object as received, handed back verbatim to `codeAction/resolve`.
    public var rawAction: JSONValue
    /// The buffer version the action was requested for; set by the editor when it lists the action.
    public var requestVersion: UInt64?

    /// Linter actions carry the linter's name so two servers' "Fix" entries can be told apart.
    public var displayTitle: String { role == .linter ? "\(serverName): \(title)" : title }

    public init(title: String, kind: String? = nil, isPreferred: Bool = false, disabledReason: String? = nil,
                edit: JSONValue? = nil, command: CodeActionCommand? = nil, data: JSONValue? = nil, diagnostics: [JSONValue] = [],
                serverID: String, serverName: String, role: ServerRole, rawAction: JSONValue) {
        self.title = title
        self.kind = kind
        self.isPreferred = isPreferred
        self.disabledReason = disabledReason
        self.edit = edit
        self.command = command
        self.data = data
        self.diagnostics = diagnostics
        self.serverID = serverID
        self.serverName = serverName
        self.role = role
        self.rawAction = rawAction
    }
}

public enum CodeActionMatching {
    /// Whether `item` says it fixes `diagnostic`: the diagnostic object the server listed is the one it published
    /// (identity), else one with the same range, code and message (a server may rewrite the object).
    public static func matches(_ item: CodeActionItem, diagnostic: LSPDiagnostic) -> Bool {
        guard let raw = diagnostic.raw else { return false }
        if item.diagnostics.contains(raw) { return true }
        func key(_ d: JSONValue) -> [JSONValue?] { [d["range"], d["code"], d["message"]] }
        let wanted = key(raw)
        return item.diagnostics.contains { key($0) == wanted }
    }
}

enum CodeActionParsing {
    /// Reads a `(Command | CodeAction)[]` answer. `null` and a wrong shape give an empty list; an entry without a title is
    /// skipped.
    static func parse(_ answer: JSONValue, serverID: String, serverName: String, role: ServerRole) -> [CodeActionItem] {
        guard let list = answer.arrayValue else { return [] }
        return list.compactMap { item(from: $0, serverID: serverID, serverName: serverName, role: role) }
    }

    static func item(from raw: JSONValue, serverID: String, serverName: String, role: ServerRole) -> CodeActionItem? {
        guard case .object = raw, let title = raw["title"]?.stringValue else { return nil }
        var command: CodeActionCommand?
        var edit: JSONValue?
        if let name = raw["command"]?.stringValue {
            // A bare `Command`: its `command` is the command's name.
            command = CodeActionCommand(command: name, arguments: raw["arguments"]?.arrayValue ?? [])
        } else if let nested = raw["command"], case .object = nested, let name = nested["command"]?.stringValue {
            command = CodeActionCommand(command: name, arguments: nested["arguments"]?.arrayValue ?? [])
        }
        if let e = raw["edit"], case .object = e { edit = e }
        return CodeActionItem(title: title, kind: raw["kind"]?.stringValue, isPreferred: raw["isPreferred"]?.boolValue ?? false,
                              disabledReason: raw["disabled"].map { $0["reason"]?.stringValue ?? "" },
                              edit: edit, command: command, data: raw["data"],
                              diagnostics: raw["diagnostics"]?.arrayValue ?? [],
                              serverID: serverID, serverName: serverName, role: role, rawAction: raw)
    }

    /// Drops a command the server did not list: an action that carries nothing else goes with it.
    static func filter(_ items: [CodeActionItem], commands: [String]) -> [CodeActionItem] {
        let allowed = Set(commands)
        return items.compactMap { item in
            guard let command = item.command, !allowed.contains(command.command) else { return item }
            var copy = item
            copy.command = nil
            return copy.edit == nil && copy.data == nil ? nil : copy
        }
    }

    /// Preferred first, then quick fixes, then the rest; stable in the order the servers were asked.
    static func order(_ items: [CodeActionItem]) -> [CodeActionItem] {
        func rank(_ item: CodeActionItem) -> Int {
            if item.isPreferred { return 0 }
            if item.kind?.hasPrefix("quickfix") == true { return 1 }
            return 2
        }
        return items.enumerated().sorted { (rank($0.element), $0.offset) < (rank($1.element), $1.offset) }.map(\.element)
    }
}

extension LSPManager {
    /// The code actions the main server and the linters offer for `range` of `snapshot`. Each server gets its own raw
    /// diagnostics that overlap `range`; a server that fails or does not answer contributes nothing. `automatic` marks
    /// a request made without the user asking (the lightbulb probe). Times out after 2 s per server.
    public func codeActions(path: String, range: Range<Int>, snapshot: CodeSnapshot,
                            automatic: Bool) async -> LSPOutcome<[CodeActionItem]> {
        let targets = requestTargets(path: path, roles: [.main, .linter])
        guard !targets.isEmpty else { return .unavailable }
        var asked: [(target: RequestTarget, diagnostics: [JSONValue])] = []
        for target in targets { asked.append((target, rawDiagnostics(path: path, serverID: target.id, overlapping: range))) }
        var outcomes: [Int: LSPOutcome<[CodeActionItem]>] = [:]
        await withTaskGroup(of: (Int, LSPOutcome<[CodeActionItem]>).self) { group in
            for (index, entry) in asked.enumerated() {
                let target = entry.target, diagnostics = entry.diagnostics
                group.addTask { [self] in
                    let outcome = await send(.codeAction, path: path, snapshot: snapshot, target: target, timeout: .seconds(2),
                                             params: { uri, encoding in
                        let start = Positions.lspPosition(utf8Offset: range.lowerBound, in: snapshot, encoding: encoding)
                        let end = Positions.lspPosition(utf8Offset: range.upperBound, in: snapshot, encoding: encoding)
                        func position(_ p: LSPPosition) -> JSONValue {
                            .object(["line": .number(Double(p.line)), "character": .number(Double(p.character))])
                        }
                        return .object([
                            "textDocument": .object(["uri": .string(uri.absoluteString)]),
                            "range": .object(["start": position(start), "end": position(end)]),
                            "context": .object(["diagnostics": .array(diagnostics), "triggerKind": .number(automatic ? 2 : 1)]),
                        ])
                    }, parse: { answer, _, _ in
                        CodeActionParsing.parse(answer, serverID: target.id, serverName: target.name, role: target.role)
                    })
                    return (index, outcome)
                }
            }
            for await (index, outcome) in group { outcomes[index] = outcome }
        }
        var merged: [CodeActionItem] = []
        var sawAnswer = false
        var firstProblem: LSPOutcome<[CodeActionItem]>?
        for (index, entry) in asked.enumerated() {
            guard let outcome = outcomes[index] else { continue }
            if case .answered(let items) = outcome {
                sawAnswer = true
                let commands = await entry.target.server.capabilities?.executeCommands ?? entry.target.capabilities?.executeCommands ?? []
                merged += CodeActionParsing.filter(items, commands: commands)
            } else if firstProblem == nil {
                firstProblem = outcome
            }
        }
        if Task.isCancelled { return .unavailable }
        if sawAnswer { return .answered(CodeActionParsing.order(merged)) }
        return firstProblem ?? .unavailable
    }

    /// Asks the item's server to fill in the rest of an action (usually its `edit`). Times out after 1 s.
    public func resolveCodeAction(path: String, item: CodeActionItem, snapshot: CodeSnapshot) async -> LSPOutcome<CodeActionItem> {
        guard let target = requestTargets(path: path, roles: [.main, .linter]).first(where: { $0.id == item.serverID }) else {
            return .unavailable
        }
        return await send(.codeActionResolve, path: path, snapshot: snapshot, target: target, timeout: .seconds(1),
                          params: { _, _ in item.rawAction },
                          parse: { answer, _, _ -> CodeActionItem? in
            guard case .object = answer else { return nil }
            var resolved = item
            if let edit = answer["edit"], case .object = edit { resolved.edit = edit }
            if let nested = answer["command"], case .object = nested, let name = nested["command"]?.stringValue {
                resolved.command = CodeActionCommand(command: name, arguments: nested["arguments"]?.arrayValue ?? [])
            }
            resolved.data = answer["data"] ?? item.data
            resolved.rawAction = answer
            return resolved
        })
    }
}

extension LSPManager {
    /// The position encoding server `serverID` of `path` negotiated (what its edits' columns count in); nil when that
    /// server does not hold the document or has not reported capabilities.
    public func positionEncoding(path: String, serverID: String) async -> PositionEncoding? {
        guard let target = requestTargets(path: path, roles: [.main, .linter]).first(where: { $0.id == serverID }) else { return nil }
        let caps = if let known = target.capabilities { known } else { await target.server.capabilities }
        return caps?.positionEncoding
    }
}
