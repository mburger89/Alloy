import AlloyCore
import CryptoKit
import AlloyPlugins
import Foundation

/// POSIX single-quote quoting of a command line typed into a terminal tab. Windows has no safe equivalent here (cmd and
/// PowerShell quote differently), so task commands are disabled there until a later task adds one.
enum ShellQuote {
    static func word(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    static func line(command: String, args: [String], cwd: String?) -> String {
        let run = ([command] + args).map(word).joined(separator: " ")
        guard let cwd else { return run }
        return "cd \(word(cwd)) && \(run)"
    }
}

/// Task commands: declarative `taskCommands` entries, palette-only, run in a new terminal tab. They start no plugin process.
extension PluginCoordinator {
    /// The registry items of one plugin's tasks. A task whose `cwd` leaves the project stays listed but disabled, with a row note.
    func taskItems(plugin id: String, tasks: [PluginTaskSpec], category: CommandCategory)
        -> [(descriptor: CommandDescriptor, isEnabled: @MainActor () -> Bool, run: @MainActor () -> Void)] {
        tasks.map { task in
            let cwd = resolvedCwd(task.cwd)
            if cwd.outside { commandNotes[id, default: []].append("Task \(task.id) has a working directory outside the project") }
            if !Self.tasksSupported { commandNotes[id, default: []].append(Self.tasksUnsupportedNote) }
            let descriptor = CommandDescriptor(id: "\(id).task.\(task.id)", title: "Run Task: \(task.title)", category: category,
                                               source: .plugin(id: id))
            let line = ShellQuote.line(command: task.command, args: task.args, cwd: cwd.path)
            let title = task.title
            return (descriptor, { !cwd.outside && Self.tasksSupported }, { [weak self] in self?.workspace?.runTerminalTask?(title, line) })
        }
    }

    static let tasksUnsupportedNote = "Task commands aren't supported on Windows yet"

    /// Task commands need POSIX quoting; Windows lists them, disabled.
    static var tasksSupported: Bool {
        #if os(Windows)
        false
        #else
        true
        #endif
    }

    /// The exact line a task types into its terminal tab (what the enable prompt shows).
    func typedLine(of task: PluginTaskSpec) -> String {
        ShellQuote.line(command: task.command, args: task.args, cwd: resolvedCwd(task.cwd).path)
    }

    /// What the user approves for a manifest: every language-server command and every task's typed line. Task lines use the
    /// manifest's own relative `cwd`, so the hash does not change with the project that is open.
    static func commandLines(_ m: PluginManifest) -> [String] {
        var lines = m.contributes.languageServers.keys.sorted().compactMap { sid -> String? in
            guard let o = m.contributes.languageServers[sid], let c = o.command else { return nil }
            return ([c] + (o.arguments ?? [])).map(ShellQuote.word).joined(separator: " ")
        }
        lines += m.contributes.taskCommands.map { ShellQuote.line(command: $0.command, args: $0.args, cwd: $0.cwd) }
        return lines
    }

    static func commandsHash(_ m: PluginManifest) -> String {
        SHA256.hash(data: Data(commandLines(m).joined(separator: "\n").utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private func resolvedCwd(_ cwd: String?) -> (path: String?, outside: Bool) {
        guard let cwd, !cwd.isEmpty, let root = workspace?.projectRoot else { return (nil, false) }
        func inside(_ path: String, _ base: String) -> Bool { path == base || path.hasPrefix(base + "/") }
        let url = (cwd.hasPrefix("/") ? URL(fileURLWithPath: cwd) : root.appendingPathComponent(cwd)).standardizedFileURL
        guard inside(url.path, root.standardizedFileURL.path) else { return (nil, true) }
        // An existing folder must not reach out of the project through a symlink either.
        if FileManager.default.fileExists(atPath: url.path),
           !inside(url.resolvingSymlinksInPath().path, root.resolvingSymlinksInPath().path) { return (nil, true) }
        return (url.path, false)
    }
}
