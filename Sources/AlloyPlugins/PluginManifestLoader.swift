import Foundation
import AlloyCore

public enum PluginManifestLoader {
    public static let fileName = "alloy-plugin.json"
    public static let maxBytes = 256 * 1024
    public static let apiVersion = 1

    /// A secret's environment variable: upper case, and never one Alloy or the loader owns.
    static func isAllowedSecretEnv(_ name: String) -> Bool {
        guard name.range(of: #"^[A-Z][A-Z0-9_]{0,63}$"#, options: .regularExpression) != nil else { return false }
        if ["PATH", "HOME", "LANG", "TMPDIR", "SHELL", "USER"].contains(name) { return false }
        return !["ALLOY_", "DYLD_", "LD_"].contains { name.hasPrefix($0) }
    }

    private static let topKeys: Set<String> = ["id", "name", "version", "apiVersion", "description", "main", "permissions",
                                               "activationEvents", "contributes"]
    private static let contributionKeys: Set<String> = ["themes", "languageServers", "settings", "commands", "taskCommands",
                                                        "panels", "mcpTools"]

    public static func load(folder: URL, pathDirs: [String]) -> Result<PluginManifest, PluginManifestError> {
        do { return .success(try parse(folder: folder, pathDirs: pathDirs)) }
        catch let e as PluginManifestError { return .failure(e) }
        catch { return .failure(.notJSON) }
    }

    // MARK: Parsing

    private static func parse(folder: URL, pathDirs: [String]) throws -> PluginManifest {
        let file = folder.appendingPathComponent(fileName)
        guard FileManager.default.fileExists(atPath: file.path) else { throw PluginManifestError.missingManifest }
        let size = (try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? Int) ?? 0
        guard size <= maxBytes else { throw PluginManifestError.tooLarge }
        guard let data = try? Data(contentsOf: file), data.count <= maxBytes else { throw PluginManifestError.tooLarge }
        guard let root = JSONValue.parse(data), case .object(let top) = root else { throw PluginManifestError.notJSON }

        for key in top.keys.sorted() where !topKeys.contains(key) { throw PluginManifestError.unknownKey(key) }

        let id = try string(top["id"], "id")
        try validateID(id, folderName: folder.lastPathComponent)
        let name = try string(top["name"], "name").trimmingCharacters(in: .whitespacesAndNewlines)
        guard (1...60).contains(name.count) else { throw PluginManifestError.invalidField("name", "1 to 60 characters") }
        let version = try string(top["version"], "version")
        guard version.range(of: #"^\d+\.\d+\.\d+(-[0-9A-Za-z.-]+)?$"#, options: .regularExpression) != nil else {
            throw PluginManifestError.invalidField("version", version)
        }
        var api = 1
        if let v = top["apiVersion"] {
            guard case .number(let n) = v, n == n.rounded(), n >= 1, let i = v.intValue else {
                throw PluginManifestError.invalidField("apiVersion", "an integer of 1 or more")
            }
            api = i
        }
        let description = try optionalString(top["description"], "description") ?? ""
        let permissions = try parsePermissions(top["permissions"])
        let activation = try parseActivation(top["activationEvents"])

        var contributes = PluginContributions()
        if let c = top["contributes"] {
            guard case .object(let obj) = c else { throw PluginManifestError.invalidField("contributes", "an object") }
            for key in obj.keys.sorted() where !contributionKeys.contains(key) {
                throw PluginManifestError.unknownKey("contributes.\(key)")
            }
            contributes = try parseContributions(obj, folder: folder)
        }

        let main = try parseMain(top["main"], folder: folder, pathDirs: pathDirs)

        if main == nil {
            if !contributes.commands.isEmpty { throw PluginManifestError.needsMain("commands") }
            if !contributes.panels.isEmpty { throw PluginManifestError.needsMain("panels") }
            if !contributes.mcpTools.isEmpty { throw PluginManifestError.needsMain("mcpTools") }
        }
        if (!contributes.languageServers.isEmpty || !contributes.taskCommands.isEmpty), !permissions.contains(.processSpawn) {
            throw PluginManifestError.missingPermission(.processSpawn)
        }
        if !contributes.mcpTools.isEmpty, !permissions.contains(.mcpTools) {
            throw PluginManifestError.missingPermission(.mcpTools)
        }

        return PluginManifest(id: id, name: name, version: version, description: description, apiVersion: api, main: main,
                              permissions: permissions, activationEvents: activation, contributes: contributes)
    }

    private static func validateID(_ id: String, folderName: String) throws {
        let ok = (1...100).contains(id.count)
            && id.range(of: #"^[a-z0-9.-]+$"#, options: .regularExpression) != nil
            && id.contains(".") && !id.hasPrefix(".") && !id.hasSuffix(".") && !id.contains("..")
        guard ok else { throw PluginManifestError.invalidField("id", id) }
        guard id == folderName else { throw PluginManifestError.invalidField("id", "must equal the folder name \"\(folderName)\"") }
    }

    private static func parsePermissions(_ v: JSONValue?) throws -> Set<PluginPermission> {
        guard let v else { return [] }
        guard case .array(let items) = v else { throw PluginManifestError.invalidField("permissions", "an array") }
        var out: Set<PluginPermission> = []
        for item in items {
            guard let s = item.stringValue, let p = PluginPermission(rawValue: s) else {
                throw PluginManifestError.invalidField("permissions", item.stringValue ?? "not a string")
            }
            out.insert(p)
        }
        return out
    }

    private static func parseActivation(_ v: JSONValue?) throws -> [PluginActivation] {
        guard let v else { return [] }
        guard case .array(let items) = v else { throw PluginManifestError.invalidField("activationEvents", "an array") }
        return try items.map { item in
            guard let s = item.stringValue else { throw PluginManifestError.invalidField("activationEvents", "not a string") }
            if s == "onStartup" { return .startup }
            for (prefix, make) in [("onCommand:", PluginActivation.command), ("onLanguage:", PluginActivation.language),
                                   ("onPanel:", PluginActivation.panel), ("onMcpTool:", PluginActivation.mcpTool)] where s.hasPrefix(prefix) {
                let rest = String(s.dropFirst(prefix.count))
                guard !rest.isEmpty else { break }
                return make(rest)
            }
            throw PluginManifestError.invalidField("activationEvents", s)
        }
    }

    // MARK: main

    private static func parseMain(_ v: JSONValue?, folder: URL, pathDirs: [String]) throws -> PluginMain? {
        guard let v else { return nil }
        guard case .object(let obj) = v else { throw PluginManifestError.invalidField("main", "an object") }
        for key in obj.keys.sorted() where key != "command" && key != "args" { throw PluginManifestError.unknownKey("main.\(key)") }
        let command = try string(obj["command"], "main.command")
        guard !command.isEmpty else { throw PluginManifestError.invalidField("main.command", "empty") }
        let args = try stringArray(obj["args"], "main.args")
        let fm = FileManager.default

        // A bare name is a file in the plugin folder when one exists, else an interpreter looked up on PATH. A bare name
        // that is neither is reported as a missing file when it looks like one (has an extension), else as not on PATH.
        let bare = !command.contains("/")
        if bare, !fm.fileExists(atPath: folder.appendingPathComponent(command).path) {
            let found = pathDirs.contains { fm.isExecutableFile(atPath: URL(fileURLWithPath: $0).appendingPathComponent(command).path) }
            if found { return PluginMain(command: command, args: args) }
            throw command.contains(".") ? PluginManifestError.mainMissing : PluginManifestError.mainNotFoundOnPath(command)
        }
        guard !command.hasPrefix("/") else { throw PluginManifestError.mainOutsideFolder }
        let base = folder.standardizedFileURL.path
        let lexical = folder.appendingPathComponent(command).standardizedFileURL
        guard lexical.path.hasPrefix(base + "/") else { throw PluginManifestError.mainOutsideFolder }
        guard fm.fileExists(atPath: lexical.path) else { throw PluginManifestError.mainMissing }
        let resolved = lexical.resolvingSymlinksInPath().path
        let resolvedBase = folder.resolvingSymlinksInPath().standardizedFileURL.path
        guard resolved.hasPrefix(resolvedBase + "/") else { throw PluginManifestError.mainOutsideFolder }
        guard fm.isExecutableFile(atPath: resolved) else { throw PluginManifestError.mainNotExecutable }
        return PluginMain(command: command, args: args)
    }

    // MARK: Contributions

    private static func parseContributions(_ obj: [String: JSONValue], folder: URL) throws -> PluginContributions {
        var c = PluginContributions()

        for item in try objects(obj["themes"], "contributes.themes") {
            try onlyKeys(item, ["path"], "contributes.themes")
            let path = try string(item["path"], "contributes.themes.path")
            guard !path.hasPrefix("/"), path.hasSuffix(".json") else { throw PluginManifestError.invalidField("contributes.themes.path", path) }
            let url = folder.appendingPathComponent(path).standardizedFileURL
            guard url.path.hasPrefix(folder.standardizedFileURL.path + "/") else {
                throw PluginManifestError.invalidField("contributes.themes.path", path)
            }
            if FileManager.default.fileExists(atPath: url.path) {
                let real = url.resolvingSymlinksInPath().path
                guard real.hasPrefix(folder.resolvingSymlinksInPath().standardizedFileURL.path + "/") else {
                    throw PluginManifestError.symlinkEscape(path)
                }
            }
            c.themes.append(PluginThemeRef(path: path))
        }

        if let v = obj["languageServers"] {
            guard case .object(let servers) = v else { throw PluginManifestError.invalidField("contributes.languageServers", "an object") }
            for (sid, value) in servers.sorted(by: { $0.key < $1.key }) {
                guard sid.range(of: #"^[a-z0-9-]{1,64}$"#, options: .regularExpression) != nil else {
                    throw PluginManifestError.invalidField("contributes.languageServers", sid)
                }
                guard let data = try? JSONEncoder().encode(value), let o = try? JSONDecoder().decode(ServerConfigOverride.self, from: data) else {
                    throw PluginManifestError.invalidField("contributes.languageServers.\(sid)", "not a server config")
                }
                c.languageServers[sid] = o
            }
        }

        var keys: Set<String> = []
        for item in try objects(obj["settings"], "contributes.settings") {
            try onlyKeys(item, ["key", "title", "type", "options", "default", "env"], "contributes.settings")
            let key = try string(item["key"], "contributes.settings.key")
            guard key.range(of: #"^[A-Za-z][A-Za-z0-9_.-]{0,63}$"#, options: .regularExpression) != nil else {
                throw PluginManifestError.invalidField("contributes.settings.key", key)
            }
            guard keys.insert(key).inserted else { throw PluginManifestError.duplicate("settings.\(key)") }
            let title = try string(item["title"], "contributes.settings.title")
            let type: PluginSettingType
            let typeName = try string(item["type"], "contributes.settings.type")
            if item["env"] != nil, typeName != "secret" { throw PluginManifestError.invalidField("contributes.settings.env", "only for secret settings") }
            switch typeName {
            case "bool": type = .bool
            case "string": type = .string
            case "number": type = .number
            case "enum":
                let options = try stringArray(item["options"], "contributes.settings.options")
                guard !options.isEmpty else { throw PluginManifestError.invalidField("contributes.settings.options", "empty") }
                type = .enumeration(options)
            case "secret":
                let env = try string(item["env"], "contributes.settings.env")
                guard Self.isAllowedSecretEnv(env) else { throw PluginManifestError.invalidField("contributes.settings.env", env) }
                guard item["default"] == nil else { throw PluginManifestError.invalidField("contributes.settings.default", "a secret has no default") }
                type = .secret(env: env)
            case let other: throw PluginManifestError.invalidField("contributes.settings.type", other)
            }
            c.settings.append(PluginSettingSpec(key: key, title: title, type: type, defaultValue: item["default"]))
        }

        var ids: Set<String> = []
        for item in try objects(obj["commands"], "contributes.commands") {
            try onlyKeys(item, ["id", "title", "shortcut", "menu", "when"], "contributes.commands")
            let id = try identifier(item["id"], "contributes.commands.id")
            guard ids.insert(id).inserted else { throw PluginManifestError.duplicate("commands.\(id)") }
            let title = try string(item["title"], "contributes.commands.title")
            var chord: KeyChord?
            if let s = item["shortcut"] {
                guard let text = s.stringValue, let parsed = KeyChord.parse(text) else {
                    throw PluginManifestError.invalidField("contributes.commands.shortcut", s.stringValue ?? "not a string")
                }
                chord = parsed
            }
            var inMenu = false
            if let m = item["menu"] {
                guard m.stringValue == "plugins" else { throw PluginManifestError.invalidField("contributes.commands.menu", m.stringValue ?? "not a string") }
                inMenu = true
            }
            var when = CommandWhen.always
            if let w = item["when"] {
                guard let s = w.stringValue else { throw PluginManifestError.invalidField("contributes.commands.when", "not a string") }
                switch s {
                case "always": when = .always
                case "codeMode": when = .codeMode
                case "editorFocused": when = .editorFocused
                default:
                    guard s.hasPrefix("language:"), s.count > "language:".count else {
                        throw PluginManifestError.invalidField("contributes.commands.when", s)
                    }
                    when = .language(String(s.dropFirst("language:".count)))
                }
            }
            c.commands.append(PluginCommandSpec(id: id, title: title, shortcut: chord, inPluginsMenu: inMenu, when: when))
        }

        ids = []
        for item in try objects(obj["taskCommands"], "contributes.taskCommands") {
            try onlyKeys(item, ["id", "title", "command", "args", "cwd"], "contributes.taskCommands")
            let id = try identifier(item["id"], "contributes.taskCommands.id")
            guard ids.insert(id).inserted else { throw PluginManifestError.duplicate("taskCommands.\(id)") }
            // These fields are typed into a terminal: a control character (Ctrl-U, Enter, Escape, ...) could rewrite or
            // end the line, so none is accepted.
            let command = try Self.plainText(try string(item["command"], "contributes.taskCommands.command"), "contributes.taskCommands.command")
            guard !command.isEmpty else { throw PluginManifestError.invalidField("contributes.taskCommands.command", "empty") }
            let title = try Self.plainText(try string(item["title"], "contributes.taskCommands.title"), "contributes.taskCommands.title")
            let args = try stringArray(item["args"], "contributes.taskCommands.args")
            for arg in args { _ = try Self.plainText(arg, "contributes.taskCommands.args") }
            let cwd = try optionalString(item["cwd"], "contributes.taskCommands.cwd")
            if let cwd {
                _ = try Self.plainText(cwd, "contributes.taskCommands.cwd")
                guard !cwd.hasPrefix("/"), !cwd.hasPrefix("~"), !(cwd.count > 1 && cwd.dropFirst().first == ":") else {
                    throw PluginManifestError.invalidField("contributes.taskCommands.cwd", "a path relative to the project")
                }
            }
            c.taskCommands.append(PluginTaskSpec(id: id, title: title, command: command, args: args, cwd: cwd))
        }

        ids = []
        for item in try objects(obj["panels"], "contributes.panels") {
            try onlyKeys(item, ["id", "title"], "contributes.panels")
            let id = try identifier(item["id"], "contributes.panels.id")
            guard ids.insert(id).inserted else { throw PluginManifestError.duplicate("panels.\(id)") }
            c.panels.append(PluginPanelSpec(id: id, title: try string(item["title"], "contributes.panels.title")))
        }

        var names: Set<String> = []
        for item in try objects(obj["mcpTools"], "contributes.mcpTools") {
            try onlyKeys(item, ["name", "description", "inputSchema"], "contributes.mcpTools")
            let name = try string(item["name"], "contributes.mcpTools.name")
            guard name.range(of: #"^[a-z0-9_]{1,40}$"#, options: .regularExpression) != nil else {
                throw PluginManifestError.invalidField("contributes.mcpTools.name", name)
            }
            guard names.insert(name).inserted else { throw PluginManifestError.duplicate("mcpTools.\(name)") }
            guard let schema = item["inputSchema"], schema["type"]?.stringValue == "object" else {
                throw PluginManifestError.invalidField("contributes.mcpTools.inputSchema", "an object schema")
            }
            c.mcpTools.append(PluginMCPToolSpec(name: name, description: try string(item["description"], "contributes.mcpTools.description"),
                                                inputSchema: schema))
        }
        return c
    }

    // MARK: Helpers

    private static func string(_ v: JSONValue?, _ field: String) throws -> String {
        guard let s = v?.stringValue else { throw PluginManifestError.invalidField(field, "a string is required") }
        return s
    }

    /// `text` unchanged, or an error when it holds a C0 control character or DEL.
    private static func plainText(_ text: String, _ field: String) throws -> String {
        if text.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F }) {
            throw PluginManifestError.invalidField(field, "control characters are not allowed")
        }
        return text
    }

    private static func optionalString(_ v: JSONValue?, _ field: String) throws -> String? {
        guard let v else { return nil }
        guard let s = v.stringValue else { throw PluginManifestError.invalidField(field, "not a string") }
        return s
    }

    private static func stringArray(_ v: JSONValue?, _ field: String) throws -> [String] {
        guard let v else { return [] }
        guard case .array(let a) = v else { throw PluginManifestError.invalidField(field, "an array") }
        return try a.map { try string($0, field) }
    }

    private static func objects(_ v: JSONValue?, _ field: String) throws -> [[String: JSONValue]] {
        guard let v else { return [] }
        guard case .array(let a) = v else { throw PluginManifestError.invalidField(field, "an array") }
        return try a.map {
            guard case .object(let o) = $0 else { throw PluginManifestError.invalidField(field, "an array of objects") }
            return o
        }
    }

    private static func onlyKeys(_ obj: [String: JSONValue], _ allowed: Set<String>, _ path: String) throws {
        for key in obj.keys.sorted() where !allowed.contains(key) { throw PluginManifestError.unknownKey("\(path).\(key)") }
    }

    private static func identifier(_ v: JSONValue?, _ field: String) throws -> String {
        let s = try string(v, field)
        guard s.range(of: #"^[A-Za-z0-9_-]{1,64}$"#, options: .regularExpression) != nil else {
            throw PluginManifestError.invalidField(field, s)
        }
        return s
    }
}
