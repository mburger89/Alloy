import Foundation

public struct ClaudeNotFound: Error, Equatable {
    public var tried: [String]
    public init(tried: [String]) { self.tried = tried }
}

public enum ClaudeLocator {
    public static func locate(override: String?, loginShellLookup: () -> String?,
                              isExecutable: (String) -> Bool, home: String) throws -> URL {
        var candidates: [String] = []
        if let override, !override.isEmpty { candidates.append(override) }
        if let found = loginShellLookup(), !found.isEmpty { candidates.append(found) }
        candidates += ["\(home)/.local/bin/claude", "/opt/homebrew/bin/claude", "/usr/local/bin/claude"]
        for c in candidates where isExecutable(c) { return URL(fileURLWithPath: c) }
        throw ClaudeNotFound(tried: candidates)
    }

    /// What one login-shell call reported.
    public struct LoginShellInfo: Sendable, Equatable {
        public var claude: String?
        public var path: String?
        public init(claude: String?, path: String?) { self.claude = claude; self.path = path }
    }

    private static let marker = "ALLOY_LOGIN_PATH="

    /// Parses the output of the login-shell probe. Login shells may print banners first: the `claude` answer
    /// is the last absolute-path line, and the PATH is the marked line.
    public static func parseLoginShellOutput(_ out: String) -> LoginShellInfo {
        var claude: String?, path: String?
        for line in out.split(whereSeparator: \.isNewline).map(String.init) {
            if line.hasPrefix(marker) {
                let value = String(line.dropFirst(marker.count))
                if !value.isEmpty { path = value }
            } else if line.hasPrefix("/") {
                claude = line
            }
        }
        return LoginShellInfo(claude: claude, path: path)
    }

    /// Merges the login shell's PATH into the existing one: login entries first, then the existing entries
    /// that are not already listed. Nothing is removed.
    public static func mergePATH(login: String?, existing: String?) -> String? {
        guard let login, !login.isEmpty else { return existing }
        var seen = Set<Substring>(), out: [Substring] = []
        for entry in login.split(separator: ":", omittingEmptySubsequences: true) + (existing ?? "").split(separator: ":", omittingEmptySubsequences: true)
        where seen.insert(entry).inserted { out.append(entry) }
        return out.joined(separator: ":")
    }

    private static let cache = NSLock()
    nonisolated(unsafe) private static var cached: LoginShellInfo?

    /// The login shell's answers, asked once per run (one shell call serves the `claude` lookup and the PATH).
    public static func loginShell() -> LoginShellInfo {
        cache.lock(); defer { cache.unlock() }
        if let cached { return cached }
        let info = runLoginShell()
        cached = info
        return info
    }

    /// Forgets the cached login-shell answers so the next call asks the shell again.
    public static func resetLoginShellCache() {
        cache.lock(); defer { cache.unlock() }
        cached = nil
        CommandLocator.resetCache()
    }

    /// `claude` as the login shell resolves it; nil on any failure.
    public static func loginShellLookup() -> String? { loginShell().claude }

    /// Runs `/bin/zsh -lc 'command -v claude; printf …$PATH'`; empty on any failure or after 5 s.
    private static func runLoginShell() -> LoginShellInfo {
        guard let out = runLoginScript("command -v claude; printf '\\n\(marker)%s\\n' \"$PATH\"") else {
            return LoginShellInfo(claude: nil, path: nil)
        }
        return parseLoginShellOutput(out)
    }

    /// Runs `script` in a zsh login shell; nil on any failure or after 5 s.
    public static func runLoginScript(_ script: String) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = ["-lc", script]
        p.standardInput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        let pipe = Pipe()
        p.standardOutput = pipe
        let done = DispatchSemaphore(value: 0)
        p.terminationHandler = { _ in done.signal() }
        do { try p.run() } catch { return nil }
        // Drain stdout concurrently so a chatty shell cannot block on a full pipe.
        let box = DataBox()
        let reader = DispatchGroup()
        reader.enter()
        DispatchQueue.global().async {
            box.data = pipe.fileHandleForReading.readDataToEndOfFile()
            reader.leave()
        }
        if done.wait(timeout: .now() + 5) == .timedOut {
            p.terminate()
            _ = done.wait(timeout: .now() + 1)
            return nil
        }
        reader.wait()
        guard p.terminationStatus == 0 else { return nil }
        return String(decoding: box.data, as: UTF8.self)
    }

    private final class DataBox: @unchecked Sendable { var data = Data() }
}

/// Finds any command by name (agents such as `codex-acp`), the way `ClaudeLocator` finds `claude`.
public enum CommandLocator {
    /// The login shell's answer first, then the usual install folders; nil when none is executable.
    public static func locate(name: String, loginShellLookup: () -> String?,
                              isExecutable: (String) -> Bool, home: String) -> URL? {
        var candidates: [String] = []
        if let found = loginShellLookup(), !found.isEmpty { candidates.append(found) }
        candidates += ["\(home)/.local/bin/\(name)", "/opt/homebrew/bin/\(name)", "/usr/local/bin/\(name)"]
        for c in candidates where isExecutable(c) { return URL(fileURLWithPath: c) }
        return nil
    }

    private static let prefix = "ALLOY_CMD "

    /// Only plain command names are looked up, so the names can be put in a shell script safely.
    static func isPlainName(_ name: String) -> Bool {
        !name.isEmpty && name.allSatisfy { $0.isLetter || $0.isNumber || "-_.".contains($0) }
    }

    /// Parses `ALLOY_CMD <name> <path>` lines; banners and unmarked lines are ignored.
    public static func parse(_ out: String) -> [String: String] {
        var result: [String: String] = [:]
        for line in out.split(whereSeparator: \.isNewline) where line.hasPrefix(prefix) {
            let rest = line.dropFirst(prefix.count)
            guard let space = rest.firstIndex(of: " ") else { continue }
            let path = rest[rest.index(after: space)...].trimmingCharacters(in: .whitespaces)
            if path.hasPrefix("/") { result[String(rest[..<space])] = path }
        }
        return result
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var cache: [String: String?] = [:]

    static func resetCache() {
        lock.lock(); defer { lock.unlock() }
        cache = [:]
    }

    /// The login shell's path for each name, asked in one shell call for the names not yet cached. Names it cannot
    /// resolve are absent from the result.
    public static func loginShellLookup(names: [String],
                                        run: (String) -> String? = ClaudeLocator.runLoginScript) -> [String: String] {
        lock.lock(); defer { lock.unlock() }
        let wanted = names.filter(isPlainName)
        let unknown = wanted.filter { cache[$0] == nil }
        if !unknown.isEmpty {
            let script = "for n in \(unknown.joined(separator: " ")); do printf 'ALLOY_CMD %s %s\\n' \"$n\" \"$(command -v \"$n\")\"; done"
            let found = run(script).map(parse) ?? [:]
            for n in unknown { cache[n] = .some(found[n]) }
        }
        var out: [String: String] = [:]
        for n in wanted { if let v = cache[n] ?? nil { out[n] = v } }
        return out
    }
}
