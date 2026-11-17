import AlloyCore
import Foundation
import MetalUICodeBuffer

/// The server a format request goes to.
public struct FormatTargetChoice: Sendable, Equatable {
    public var serverID: String
    public var role: ServerRole

    public init(serverID: String, role: ServerRole) {
        self.serverID = serverID
        self.role = role
    }
}

public enum FormatterChoice {
    /// Picks the server that formats a file. A server the user named for the language (`preferred`) wins when it can
    /// format; otherwise a capable linter (Ruff, Biome: attached only when the project has their config, so being there
    /// means the project chose it) wins over the main server; otherwise a capable main server; otherwise nil.
    /// A target whose capabilities are not known yet cannot format.
    static func choose(targets: [LSPManager.RequestTarget], rangeOnly: Bool, preferred: String?,
                       configExists: (String) -> Bool = { _ in true }) -> LSPManager.RequestTarget? {
        let capable = targets.filter { target in
            guard let caps = target.capabilities, configExists(target.id) else { return false }
            return rangeOnly ? caps.documentRangeFormatting : caps.documentFormatting
        }
        if let preferred, let match = capable.first(where: { $0.id == preferred }) { return match }
        return capable.first(where: { $0.role == .linter }) ?? capable.first(where: { $0.role == .main })
    }
}

extension LSPManager {
    /// The format targets of `path` with their capabilities filled in (a server that just became ready may not have
    /// reported them to the manager yet).
    private func formatTargets(path: String) async -> [RequestTarget] {
        var out: [RequestTarget] = []
        for var target in requestTargets(path: path, roles: [.main, .linter]) {
            if target.capabilities == nil {
                _ = try? await target.server.connection()   // waits for a starting server
                target.capabilities = await target.server.capabilities
            }
            out.append(target)
        }
        return out
    }

    /// Which server would format `path` (the whole document, or a range) given the user's `formatters` setting
    /// (language id to server id); nil when none can.
    public func formatChoice(path: String, formatters: [String: String], rangeOnly: Bool) async -> FormatTargetChoice? {
        let targets = await formatTargets(path: path)
        let language = targets.first?.languageID ?? ""
        guard let target = FormatterChoice.choose(targets: targets, rangeOnly: rangeOnly, preferred: formatters[language]) else { return nil }
        return FormatTargetChoice(serverID: target.id, role: target.role)
    }

    /// Asks `serverID` to format `path` (as of `snapshot`), all of it or the byte `range`, and reads the edits against
    /// `snapshot`. A reply of null is no edits; an edit that splits a character or overlaps another is `.failed`.
    public func format(path: String, snapshot: CodeSnapshot, range: Range<Int>?, serverID: String,
                       timeout: Duration) async -> LSPOutcome<[ByteEdit]> {
        guard let target = await formatTargets(path: path).first(where: { $0.id == serverID }) else { return .unavailable }
        let feature: Feature = range == nil ? .formatting : .rangeFormatting
        let outcome: LSPOutcome<FormatAnswer> = await send(
            feature, path: path, snapshot: snapshot, target: target, timeout: timeout,
            params: { uri, encoding in
                var params: [String: JSONValue] = [
                    "textDocument": .object(["uri": .string(uri.absoluteString)]),
                    "options": .object(["tabSize": .number(4), "insertSpaces": .bool(true)]),
                ]
                if let range {
                    let start = Positions.lspPosition(utf8Offset: range.lowerBound, in: snapshot, encoding: encoding)
                    let end = Positions.lspPosition(utf8Offset: range.upperBound, in: snapshot, encoding: encoding)
                    params["range"] = .object([
                        "start": .object(["line": .number(Double(start.line)), "character": .number(Double(start.character))]),
                        "end": .object(["line": .number(Double(end.line)), "character": .number(Double(end.character))]),
                    ])
                }
                return .object(params)
            },
            parse: { answer, encoding, snapshot in
                let list: [JSONValue]
                if case .null = answer { list = [] } else if let array = answer.arrayValue { list = array } else { return nil }
                do { return .edits(try TextEditParsing.byteEdits(list, snapshot: snapshot, encoding: encoding)) } catch { return .invalid }
            })
        switch outcome {
        case .answered(.edits(let edits)): return .answered(edits)
        case .answered(.invalid): return .failed("server sent an invalid edit")
        case .unavailable: return .unavailable
        case .stale: return .stale
        case .timedOut: return .timedOut
        case .failed(let message): return .failed(message)
        }
    }
}

/// A format reply read off the main actor: usable edits, or an edit that cannot be applied.
enum FormatAnswer: Sendable {
    case edits([ByteEdit])
    case invalid
}
