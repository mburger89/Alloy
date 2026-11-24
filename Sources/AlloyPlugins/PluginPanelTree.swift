import AlloyCore
import Foundation

/// One choice of a panel picker.
public struct PluginPanelOption: Equatable, Sendable {
    public var value: String
    public var title: String
    public init(value: String, title: String) {
        self.value = value
        self.title = title
    }
}

/// A node of a plugin panel in Alloy's closed widget vocabulary. Every node carries a `key`, unique within its panel.
public indirect enum PluginPanelNode: Equatable, Sendable {
    case text(key: String, text: String, role: PluginColorRole?)
    case button(key: String, title: String)
    case toggle(key: String, title: String, isOn: Bool)
    case textField(key: String, placeholder: String, text: String)
    case picker(key: String, title: String, options: [PluginPanelOption], selection: String)
    case list(key: String, rows: [PluginPanelNode])
    case vstack(key: String, children: [PluginPanelNode])
    case hstack(key: String, children: [PluginPanelNode])
    case divider(key: String)

    public var key: String {
        switch self {
        case .text(let key, _, _), .button(let key, _), .toggle(let key, _, _), .textField(let key, _, _),
             .picker(let key, _, _, _), .list(let key, _), .vstack(let key, _), .hstack(let key, _), .divider(let key):
            key
        }
    }
}

public enum PluginPanelError: Error, Equatable, Sendable {
    case duplicateKey(String), tooManyElements, tooDeep, badNode(String)

    public var description: String {
        switch self {
        case .duplicateKey(let key): "panel rejected: duplicate key \"\(key)\""
        case .tooManyElements: "panel rejected: too many elements"
        case .tooDeep: "panel rejected: nested too deeply"
        case .badNode(let why): "panel rejected: \(why)"
        }
    }
}

/// A validated panel tree: unique keys, at most `maxElements` nodes, at most 16 levels deep.
public struct PluginPanelTree: Equatable, Sendable {
    public static let maxDepth = 16
    public var root: PluginPanelNode

    public init(root: PluginPanelNode) { self.root = root }

    public static func parse(_ json: JSONValue, maxElements: Int) -> Result<PluginPanelTree, PluginPanelError> {
        var keys: Set<String> = []
        var count = 0
        func node(_ value: JSONValue, depth: Int) throws -> PluginPanelNode {
            guard depth <= maxDepth else { throw PluginPanelError.tooDeep }
            count += 1
            guard count <= maxElements else { throw PluginPanelError.tooManyElements }
            guard let type = value["type"]?.stringValue else { throw PluginPanelError.badNode("a node has no type") }
            guard let key = value["key"]?.stringValue, !key.isEmpty, key.count <= 128 else {
                throw PluginPanelError.badNode("a \(type) has no key")
            }
            guard keys.insert(key).inserted else { throw PluginPanelError.duplicateKey(key) }
            func string(_ name: String, required: Bool = true) throws -> String {
                if let s = value[name]?.stringValue { return s }
                if value[name] == nil, !required { return "" }
                throw PluginPanelError.badNode("\(type) \"\(key)\" needs a string \(name)")
            }
            func children(_ name: String) throws -> [PluginPanelNode] {
                guard let items = value[name]?.arrayValue else { throw PluginPanelError.badNode("\(type) \"\(key)\" needs \(name)") }
                return try items.map { try node($0, depth: depth + 1) }
            }
            switch type {
            case "text":
                var role: PluginColorRole?
                if let raw = value["role"] {
                    guard let name = raw.stringValue, let r = PluginColorRole(rawValue: name) else {
                        throw PluginPanelError.badNode("text \"\(key)\" has an unknown role")
                    }
                    role = r
                }
                return .text(key: key, text: try string("text"), role: role)
            case "button": return .button(key: key, title: try string("title"))
            case "toggle": return .toggle(key: key, title: try string("title"), isOn: value["isOn"]?.boolValue ?? false)
            case "textField":
                return .textField(key: key, placeholder: try string("placeholder", required: false), text: try string("text", required: false))
            case "picker":
                guard let raw = value["options"]?.arrayValue else { throw PluginPanelError.badNode("picker \"\(key)\" needs options") }
                var options: [PluginPanelOption] = []
                for item in raw {
                    guard let v = item["value"]?.stringValue, let t = item["title"]?.stringValue else {
                        throw PluginPanelError.badNode("picker \"\(key)\" has a bad option")
                    }
                    options.append(PluginPanelOption(value: v, title: t))
                }
                return .picker(key: key, title: try string("title", required: false), options: options,
                               selection: try string("selection", required: false))
            case "list": return .list(key: key, rows: try children("rows"))
            case "vstack": return .vstack(key: key, children: try children("children"))
            case "hstack": return .hstack(key: key, children: try children("children"))
            case "divider": return .divider(key: key)
            default: throw PluginPanelError.badNode("unknown widget \"\(type)\"")
            }
        }
        do { return .success(PluginPanelTree(root: try node(json, depth: 1))) } catch let e as PluginPanelError { return .failure(e) } catch {
            return .failure(.badNode("\(error)"))
        }
    }
}
