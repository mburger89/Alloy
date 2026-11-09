import Foundation

public enum Priority: String, Sendable, Equatable {
    case now, next, later
}

public enum ControlSubtype: Sendable, Equatable {
    case interrupt
    case setPermissionMode(String)
    case setModel(String)
    case initialize
}

/// One block of a user message.
public enum UserContent: Sendable, Equatable {
    case text(String)
    case image(mediaType: String, base64: String)
}

/// Lines written to the CLI's stdin.
public enum OutboundMessage: Sendable, Equatable {
    case user(content: [UserContent], uuid: UUID, priority: Priority?)
    /// `updatedPermissions` nil omits the key.
    case allow(requestID: String, updatedInput: JSONValue, updatedPermissions: [JSONValue]? = nil)
    case deny(requestID: String, message: String)
    case control(requestID: String, ControlSubtype)
    /// The answer to a control request Alloy does not handle, so the CLI never waits for one.
    case controlError(requestID: String, message: String)

    public static func user(text: String, uuid: UUID, priority: Priority?) -> OutboundMessage {
        .user(content: [.text(text)], uuid: uuid, priority: priority)
    }

    /// Compact JSON followed by a newline.
    public func line() -> Data {
        let tree: JSONValue
        switch self {
        case .user(let content, let uuid, let priority):
            let wire: JSONValue
            if content.count == 1, case .text(let text) = content[0] {
                wire = .string(text)
            } else {
                wire = .array(content.map {
                    switch $0 {
                    case .text(let t):
                        .object(["type": .string("text"), "text": .string(t)])
                    case .image(let mediaType, let base64):
                        .object(["type": .string("image"),
                                 "source": .object(["type": .string("base64"), "media_type": .string(mediaType),
                                                    "data": .string(base64)])])
                    }
                })
            }
            var o: [String: JSONValue] = [
                "type": .string("user"),
                "message": .object(["role": .string("user"), "content": wire]),
                "parent_tool_use_id": .null,
                "uuid": .string(uuid.uuidString.lowercased()),
            ]
            if let priority { o["priority"] = .string(priority.rawValue) }
            tree = .object(o)
        case .allow(let id, let input, let permissions):
            var inner: [String: JSONValue] = ["behavior": .string("allow"), "updatedInput": input]
            // Never echo a suggestion that would write a settings file (`addRules` ... `localSettings`).
            if let permissions {
                let kept = permissions.filter(Self.writesNoSettingsFile)
                if !kept.isEmpty { inner["updatedPermissions"] = .array(kept) }
            }
            tree = Self.controlResponse(id, inner)
        case .deny(let id, let message):
            tree = Self.controlResponse(id, ["behavior": .string("deny"), "message": .string(message)])
        case .controlError(let id, let message):
            tree = .object(["type": .string("control_response"),
                            "response": .object(["subtype": .string("error"), "request_id": .string(id),
                                                 "error": .string(message)])])
        case .control(let id, let subtype):
            var req: [String: JSONValue]
            switch subtype {
            case .interrupt: req = ["subtype": .string("interrupt")]
            case .initialize: req = ["subtype": .string("initialize")]
            case .setModel(let m): req = ["subtype": .string("set_model"), "model": .string(m)]
            case .setPermissionMode(let m): req = ["subtype": .string("set_permission_mode"), "mode": .string(m)]
            }
            tree = .object(["type": .string("control_request"), "request_id": .string(id), "request": .object(req)])
        }
        var data = (try? JSONSerialization.data(withJSONObject: tree.foundationObject,
                                                options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data("{}".utf8)
        data.append(UInt8(ascii: "\n"))
        return data
    }

    /// Allow-list: only updates aimed at `session` or `cliArg` are sent; anything else (no destination, a settings
    /// file, an unknown value, a non-object) is dropped because it could write a settings file.
    private static func writesNoSettingsFile(_ update: JSONValue) -> Bool {
        guard let destination = update.objectValue?["destination"]?.stringValue else { return false }
        return destination == "session" || destination == "cliArg"
    }

    private static func controlResponse(_ id: String, _ inner: [String: JSONValue]) -> JSONValue {
        .object(["type": .string("control_response"),
                 "response": .object(["subtype": .string("success"), "request_id": .string(id),
                                      "response": .object(inner)])])
    }
}

extension JSONValue {
    /// Foundation object graph suitable for `JSONSerialization`.
    var foundationObject: Any {
        switch self {
        case .null: NSNull()
        case .bool(let b): b
        case .number(let n): n
        case .string(let s): s
        case .array(let a): a.map(\.foundationObject)
        case .object(let o): o.mapValues(\.foundationObject)
        }
    }
}
