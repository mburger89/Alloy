import AlloyCore
import Foundation

/// The language servers Alloy knows about: a built-in table with the user's settings overrides applied.
public struct ServerRegistry: Sendable {
    public let all: [ServerConfig]
    /// Extension and file-name lookups, built once. Overridden servers come first so a user's claim beats a built-in.
    private let byFileName: [String: ServerConfig]
    private let byExtension: [String: ServerConfig]
    /// Enabled linters per file name and extension, in table order then user-added ids sorted.
    private let lintersByFileName: [String: [ServerConfig]]
    private let lintersByExtension: [String: [ServerConfig]]

    public init(builtIn: [ServerConfig] = ServerRegistry.builtIn, overrides: [String: ServerConfigOverride] = [:]) {
        var servers: [ServerConfig] = []
        var claimsFirst: [Bool] = []
        for base in builtIn {
            var s = base
            var claims = false
            if let o = overrides[base.id] {
                if let v = o.name { s.name = v }
                if let v = o.languageID { s.languageID = v }
                if let v = o.languageIDs { s.languageIDs = v }
                if let v = o.extensions { s.extensions = v; claims = true }
                if let v = o.fileNames { s.fileNames = v; claims = true }
                if let v = o.command, !v.isEmpty { s.command = v }
                if let v = o.arguments { s.arguments = v }
                if let v = o.initializationOptions { s.initializationOptions = v }
                if let v = o.enabled { s.enabled = v }
                if let v = o.role { s.role = v; claims = true }
                if let v = o.clippy { s.clippy = v }
            }
            servers.append(s)
            claimsFirst.append(claims)
        }
        let known = Set(builtIn.map(\.id))
        for id in overrides.keys.sorted() where !known.contains(id) {
            let o = overrides[id]!
            guard let command = o.command, !command.isEmpty,
                  !(o.extensions ?? []).isEmpty || !(o.fileNames ?? []).isEmpty else { continue }
            servers.append(ServerConfig(id: id, name: o.name ?? id, languageID: o.languageID ?? id, languageIDs: o.languageIDs ?? [:],
                                        extensions: o.extensions ?? [], fileNames: o.fileNames ?? [],
                                        command: command, arguments: o.arguments ?? [],
                                        initializationOptions: o.initializationOptions, enabled: o.enabled ?? true,
                                        role: o.role ?? .main, clippy: o.clippy ?? false))
            claimsFirst.append(true)
        }
        all = servers

        let order = servers.indices.filter { claimsFirst[$0] } + servers.indices.filter { !claimsFirst[$0] }
        var names: [String: ServerConfig] = [:], exts: [String: ServerConfig] = [:]
        for i in order where servers[i].enabled && servers[i].role == .main {
            for n in servers[i].fileNames where names[n] == nil { names[n] = servers[i] }
            for e in servers[i].extensions {
                let key = e.hasPrefix(".") ? String(e.dropFirst()).lowercased() : e.lowercased()
                if exts[key] == nil { exts[key] = servers[i] }
            }
        }
        byFileName = names
        byExtension = exts

        var lNames: [String: [ServerConfig]] = [:], lExts: [String: [ServerConfig]] = [:]
        for s in servers where s.enabled && s.role == .linter {
            for n in Set(s.fileNames) { lNames[n, default: []].append(s) }
            for e in Set(s.extensions.map { $0.hasPrefix(".") ? String($0.dropFirst()).lowercased() : $0.lowercased() }) {
                lExts[e, default: []].append(s)
            }
        }
        lintersByFileName = lNames
        lintersByExtension = lExts
    }

    /// The enabled linters for a path (file name and extension matches, each linter once), in table order then
    /// user-added ids sorted.
    public func linters(forPath path: String) -> [ServerConfig] {
        let name = (path as NSString).lastPathComponent
        let ext = (name as NSString).pathExtension.lowercased()
        let hits = (lintersByFileName[name] ?? []) + (ext.isEmpty ? [] : lintersByExtension[ext] ?? [])
        var seen = Set<String>()
        let unique = hits.filter { seen.insert($0.id).inserted }
        return all.filter { s in unique.contains { $0.id == s.id } }
    }

    /// The initialization options to send: the config's own, plus `check.command = "clippy"` when `clippy` is on and
    /// the user's options do not already set `check.command`.
    public static func effectiveInitializationOptions(_ config: ServerConfig) -> JSONValue? {
        guard config.clippy else { return config.initializationOptions }
        var root: [String: JSONValue] = [:]
        if case .object(let o)? = config.initializationOptions { root = o }
        else if config.initializationOptions != nil, config.initializationOptions != .null { return config.initializationOptions }
        var check: [String: JSONValue] = [:]
        if case .object(let c)? = root["check"] { check = c }
        else if let v = root["check"], v != .null { return config.initializationOptions }
        if check["command"] == nil { check["command"] = .string("clippy") }
        root["check"] = .object(check)
        return .object(root)
    }

    /// The enabled server for a path: the file name first, then the lowercased extension.
    public func server(forPath path: String) -> ServerConfig? {
        let name = (path as NSString).lastPathComponent
        if let s = byFileName[name] { return s }
        let ext = (name as NSString).pathExtension.lowercased()
        return ext.isEmpty ? nil : byExtension[ext]
    }

    /// The LSP language id for a path: the extension's own id when the server lists one, else the server's.
    public func languageID(forPath path: String) -> String? {
        guard let server = server(forPath: path) else { return nil }
        let name = (path as NSString).lastPathComponent
        if byFileName[name] != nil { return server.languageID }
        let ext = (name as NSString).pathExtension.lowercased()
        return server.languageIDs[ext] ?? server.languageID
    }

    public static let builtIn: [ServerConfig] = [
        entry("rust-analyzer", "rust-analyzer", "rust", "rust-analyzer", [], ["rs"]),
        entry("sourcekit-lsp", "sourcekit-lsp", "swift", "sourcekit-lsp", [], ["swift"]),
        entry("typescript-language-server", "TypeScript", "typescript", "typescript-language-server", ["--stdio"], ["ts", "tsx", "js", "jsx", "mjs", "cjs"],
              ids: ["tsx": "typescriptreact", "js": "javascript", "jsx": "javascriptreact", "mjs": "javascript", "cjs": "javascript"]),
        entry("pyright", "Pyright", "python", "pyright-langserver", ["--stdio"], ["py", "pyi"]),
        entry("gopls", "gopls", "go", "gopls", [], ["go"]),
        entry("clangd", "clangd", "cpp", "clangd", [], ["c", "h", "cc", "cpp", "cxx", "hpp", "hh", "m", "mm"],
              ids: ["c": "c", "h": "c", "m": "objective-c", "mm": "objective-cpp"]),
        entry("lua-language-server", "Lua", "lua", "lua-language-server", [], ["lua"]),
        entry("zls", "zls", "zig", "zls", [], ["zig"]),
        entry("ruby-lsp", "Ruby LSP", "ruby", "ruby-lsp", [], ["rb"], ["Gemfile", "Rakefile"]),
        entry("elixir-ls", "ElixirLS", "elixir", "elixir-ls", [], ["ex", "exs"]),
        entry("bash-language-server", "Bash", "shellscript", "bash-language-server", ["start"], ["sh", "bash", "zsh"]),
        entry("yaml-language-server", "YAML", "yaml", "yaml-language-server", ["--stdio"], ["yml", "yaml"]),
        entry("vscode-json-language-server", "JSON", "json", "vscode-json-language-server", ["--stdio"], ["json", "jsonc"], ids: ["jsonc": "jsonc"]),
        entry("vscode-css-language-server", "CSS", "css", "vscode-css-language-server", ["--stdio"], ["css", "scss", "less"], ids: ["scss": "scss", "less": "less"]),
        entry("vscode-html-language-server", "HTML", "html", "vscode-html-language-server", ["--stdio"], ["html", "htm"]),
        entry("marksman", "Marksman", "markdown", "marksman", ["server"], ["md", "markdown"]),
        entry("taplo", "Taplo", "toml", "taplo", ["lsp", "stdio"], ["toml"]),
        entry("kotlin-language-server", "Kotlin", "kotlin", "kotlin-language-server", [], ["kt", "kts"]),
        entry("jdtls", "Eclipse JDT LS", "java", "jdtls", [], ["java"]),
        entry("ocamllsp", "OCaml LSP", "ocaml", "ocamllsp", [], ["ml", "mli"]),
        entry("haskell-language-server", "Haskell", "haskell", "haskell-language-server-wrapper", ["--lsp"], ["hs"]),
        entry("dart", "Dart", "dart", "dart", ["language-server"], ["dart"]),
        entry("terraform-ls", "Terraform", "terraform", "terraform-ls", ["serve"], ["tf"]),
        entry("nil", "nil", "nix", "nil", [], ["nix"]),
    ] + linterTable

    private static let jsExtensions = ["js", "jsx", "mjs", "cjs", "ts", "tsx"]
    private static let jsLanguageIDs = ["tsx": "typescriptreact", "ts": "typescript", "js": "javascript", "jsx": "javascriptreact",
                                        "mjs": "javascript", "cjs": "javascript"]

    /// Linters: document sync and diagnostics only.
    private static let linterTable: [ServerConfig] = [
        ServerConfig(id: "ruff", name: "Ruff", languageID: "python", extensions: ["py", "pyi"], command: "ruff", arguments: ["server"], role: .linter),
        ServerConfig(id: "eslint", name: "ESLint", languageID: "javascript", languageIDs: jsLanguageIDs, extensions: jsExtensions,
                     command: "vscode-eslint-language-server", arguments: ["--stdio"], role: .linter,
                     configurationAnswers: ["": .object([
                         "validate": .string("on"), "run": .string("onType"),
                         "onIgnoredFiles": .string("off"), "quiet": .bool(false), "format": .bool(false),
                         "codeActionOnSave": .object(["enable": .bool(false), "mode": .string("all")]),
                         "workingDirectory": .object(["mode": .string("auto")]),
                         "nodePath": .null, "experimental": .object([:]), "problems": .object([:]),
                         "rulesCustomizations": .array([]),
                         "codeAction": .object(["disableRuleComment": .object(["enable": .bool(false)]),
                                                "showDocumentation": .object(["enable": .bool(false)])]),
                     ])],
                     requiresConfigFiles: ["eslint.config.*", ".eslintrc", ".eslintrc.*", "package.json#eslintConfig"]),
        ServerConfig(id: "biome", name: "Biome", languageID: "javascript", languageIDs: jsLanguageIDs.merging(["json": "json", "jsonc": "jsonc", "css": "css"]) { a, _ in a },
                     extensions: jsExtensions + ["json", "jsonc", "css"], command: "biome", arguments: ["lsp-proxy"], role: .linter,
                     requiresConfigFiles: ["biome.json", "biome.jsonc"]),
        ServerConfig(id: "golangci-lint", name: "golangci-lint", languageID: "go", extensions: ["go"], command: "golangci-lint-langserver",
                     initializationOptions: .object(["command": .array(["golangci-lint", "run", "--output.json.path=stdout", "--show-stats=false"].map { .string($0) })]),
                     role: .linter),
        ServerConfig(id: "efm", name: "efm-langserver", languageID: "plaintext", command: "efm-langserver", role: .linter),
    ]

    private static func entry(_ id: String, _ name: String, _ lang: String, _ command: String, _ args: [String],
                              _ exts: [String], _ files: [String] = [], ids: [String: String] = [:]) -> ServerConfig {
        ServerConfig(id: id, name: name, languageID: lang, languageIDs: ids, extensions: exts, fileNames: files, command: command, arguments: args)
    }
}

/// Resolves a server command to an absolute executable path. Bare names are searched on the login shell's PATH
/// (a GUI app's own PATH lacks the user's tool directories); `sourcekit-lsp` also falls back to `xcrun --find`.
/// When the login PATH is unavailable, the process PATH plus the usual tool directories is searched instead.
/// Answers are cached per command, except a miss produced while the login PATH was unavailable; `invalidate()`
/// clears the cache and re-reads the login PATH.
public struct ServerLocator: Sendable {
    private let loginPATH: @Sendable () -> String?
    private let xcrunFind: @Sendable (String) -> String?
    private let resetLoginPATH: @Sendable () -> Void
    private let developerDirectorySelected: @Sendable () -> Bool
    private let processPATH: String
    private let home: String
    private let cache = Cache()

    public init(loginPATH: @escaping @Sendable () -> String?, xcrunFind: @escaping @Sendable (String) -> String?,
                resetLoginPATH: @escaping @Sendable () -> Void = {},
                developerDirectorySelected: @escaping @Sendable () -> Bool = { DeveloperDirectory.isSelected() },
                processPATH: String = ProcessInfo.processInfo.environment["PATH"] ?? "",
                home: String = NSHomeDirectory()) {
        self.loginPATH = loginPATH
        self.xcrunFind = xcrunFind
        self.resetLoginPATH = resetLoginPATH
        self.developerDirectorySelected = developerDirectorySelected
        self.processPATH = processPATH
        self.home = home
    }

    /// The real locator: PATH from the login shell, `xcrun --find` for the Xcode toolchain.
    public static var live: ServerLocator {
        ServerLocator(loginPATH: { ClaudeLocator.loginShell().path },
                      xcrunFind: { runTool("/usr/bin/xcrun", ["--find", $0], timeout: 5) },
                      resetLoginPATH: { ClaudeLocator.resetLoginShellCache() })
    }

    /// Forgets every answer, misses included, and makes the next lookup re-read the login PATH.
    public func invalidate() {
        cache.clear()
        resetLoginPATH()
    }

    public func resolve(_ command: String) -> String? {
        if let hit = cache.get(command) { return hit.path }
        let (found, loginAvailable) = lookup(command)
        if found != nil || loginAvailable { cache.set(command, found) }
        return found
    }

    private func lookup(_ rawCommand: String) -> (String?, Bool) {
        var command = rawCommand
        if command.hasPrefix("~/") { command = home + String(command.dropFirst()) }
        guard !command.isEmpty else { return (nil, true) }
        let fm = FileManager.default
        func executable(_ p: String) -> Bool {
            var isDir: ObjCBool = false
            return fm.fileExists(atPath: p, isDirectory: &isDir) && !isDir.boolValue && fm.isExecutableFile(atPath: p)
        }
        if command.hasPrefix("/") { return (executable(command) ? command : nil, true) }
        if command.contains("/") { return (nil, true) }
        let dirs: [Substring]
        var loginAvailable = true
        if let path = loginPATH(), !path.isEmpty {
            dirs = path.split(separator: ":", omittingEmptySubsequences: true)
        } else {
            loginAvailable = false
            let extras = ["/opt/homebrew/bin", "/usr/local/bin", "\(home)/.cargo/bin", "\(home)/go/bin", "\(home)/.local/bin",
                          "\(home)/.bun/bin", "\(home)/.npm-global/bin", "/usr/bin"]
            dirs = processPATH.split(separator: ":", omittingEmptySubsequences: true) + extras.map { Substring($0) }
        }
        for dir in dirs {
            let candidate = "\(dir)/\(command)"
            if executable(candidate) { return (candidate, loginAvailable) }
        }
        // `/usr/bin/xcrun` without a selected toolchain shows the install-developer-tools dialog, so it is never run then.
        if command == "sourcekit-lsp", developerDirectorySelected(), let p = xcrunFind(command), executable(p) { return (p, loginAvailable) }
        return (nil, loginAvailable)
    }

    private final class Cache: @unchecked Sendable {
        struct Hit { var path: String? }
        private let lock = NSLock()
        private var map: [String: Hit] = [:]
        func get(_ k: String) -> Hit? { lock.lock(); defer { lock.unlock() }; return map[k] }
        func set(_ k: String, _ v: String?) { lock.lock(); defer { lock.unlock() }; map[k] = Hit(path: v) }
        func clear() { lock.lock(); defer { lock.unlock() }; map = [:] }
    }

    private final class DataBox: @unchecked Sendable { var data = Data() }

    /// Runs a tool and returns its trimmed stdout; nil on failure, empty output, or after `timeout` seconds
    /// (the process is then terminated).
    static func runTool(_ executable: String, _ arguments: [String], timeout: TimeInterval) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: executable)
        p.arguments = arguments
        p.standardInput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        let pipe = Pipe()
        p.standardOutput = pipe
        let done = DispatchSemaphore(value: 0)
        p.terminationHandler = { _ in done.signal() }
        do { try p.run() } catch { return nil }
        let box = DataBox()
        let reader = DispatchGroup()
        reader.enter()
        DispatchQueue.global().async {
            box.data = pipe.fileHandleForReading.readDataToEndOfFile()
            reader.leave()
        }
        if done.wait(timeout: .now() + timeout) == .timedOut {
            p.terminate()
            _ = done.wait(timeout: .now() + 1)
            return nil
        }
        reader.wait()
        guard p.terminationStatus == 0 else { return nil }
        let s = String(decoding: box.data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return s.isEmpty ? nil : s
    }
}
