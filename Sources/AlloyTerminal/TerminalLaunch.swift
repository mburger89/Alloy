#if !os(Windows)

import AlloyCore

/// What to run for one pane: executable, argv, environment, working directory.
public struct TerminalLaunch: Equatable, Sendable {
    public var executable: String
    public var argv: [String]
    public var env: [String: String]
    public var cwd: String
    /// One-line pane notices, in order.
    public var notices: [String]

    public init(executable: String, argv: [String], env: [String: String], cwd: String, notices: [String]) {
        self.executable = executable
        self.argv = argv
        self.env = env
        self.cwd = cwd
        self.notices = notices
    }
}

/// Pure planning of a shell launch. The filesystem is reached only through the closures.
public enum TerminalLaunchPlanner {
    public static func plan(settings: TerminalSettings, environment: [String: String], paneCwd: String?,
                            projectRoot: String, home: String,
                            isExecutable: (String) -> Bool, isDirectory: (String) -> Bool) -> TerminalLaunch {
        var notices: [String] = []

        // Shell: configured, then $SHELL, then /bin/zsh, then /bin/sh.
        func nonEmpty(_ value: String?) -> String? { (value?.isEmpty == false) ? value : nil }
        let wanted = nonEmpty(settings.shellPath) ?? nonEmpty(environment["SHELL"]) ?? "/bin/zsh"
        var shell = wanted
        if !isExecutable(wanted) {
            shell = ["/bin/zsh", "/bin/sh"].first { $0 != wanted && isExecutable($0) } ?? "/bin/sh"
            notices.append("Shell \(wanted) not found, using \(shell)")
        }
        let name = shell.split(separator: "/").last.map(String.init) ?? shell

        // Environment.
        var env = environment.filter { !$0.key.hasPrefix("ALLOY_") }
        env["TERM"] = "xterm-256color"
        env["COLORTERM"] = "truecolor"
        let locale = ["LC_ALL", "LC_CTYPE", "LANG"].compactMap { nonEmpty(env[$0]) }.first ?? ""
        let lowered = locale.lowercased()
        if !(lowered.contains("utf-8") || lowered.contains("utf8")) {
            env["LANG"] = "en_US.UTF-8"
            env["LC_ALL"] = nil
            env["LC_CTYPE"] = nil
        }

        // Working directory: pane, then project root, then home.
        var cwd = home
        let rootOK = isDirectory(projectRoot)
        if let paneCwd, isDirectory(paneCwd) {
            cwd = paneCwd
        } else {
            if rootOK { cwd = projectRoot }
            if paneCwd != nil || !rootOK {
                notices.append("Directory \(paneCwd ?? projectRoot) not found, using \(cwd)")
            }
        }

        return TerminalLaunch(executable: shell, argv: ["-" + name], env: env, cwd: cwd, notices: notices)
    }
}

#endif
