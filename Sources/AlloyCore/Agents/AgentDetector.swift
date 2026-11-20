import Foundation

public enum AgentStatus: Sendable, Equatable {
    case installed(URL)
    case missing(installHint: String?)
}

/// Finds agent commands on the login PATH: one login-shell call resolves every command name.
public struct AgentDetector: Sendable {
    public var resolve: @Sendable ([String]) -> [String: String]
    public var isExecutable: @Sendable (String) -> Bool
    public var home: String
    /// Runs `<command> --help` and returns its output (nil when it cannot run); used for the Gemini flag probe.
    public var helpRunner: @Sendable (URL) -> String?

    public init(resolve: @escaping @Sendable ([String]) -> [String: String] = { CommandLocator.loginShellLookup(names: $0) },
                isExecutable: @escaping @Sendable (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) },
                home: String = NSHomeDirectory(),
                helpRunner: @escaping @Sendable (URL) -> String? = AgentDetector.runHelp) {
        self.resolve = resolve; self.isExecutable = isExecutable; self.home = home; self.helpRunner = helpRunner
    }

    /// One status per definition, in order. A command given as a path is checked directly.
    public func detect(_ defs: [AgentDefinition]) -> [AgentStatus] {
        let names = defs.map(\.command).filter { !$0.contains("/") }
        let found = resolve(names)
        return defs.map { def in
            if def.command.contains("/") {
                return isExecutable(def.command) ? .installed(URL(fileURLWithPath: def.command))
                                                 : .missing(installHint: def.installHint)
            }
            if let url = CommandLocator.locate(name: def.command, loginShellLookup: { found[def.command] },
                                               isExecutable: isExecutable, home: home) {
                return .installed(url)
            }
            return .missing(installHint: def.installHint)
        }
    }

    /// `--acp` when Gemini's help lists it, else the older `--experimental-acp`.
    public static func geminiArgs(helpOutput: String) -> [String] {
        let tokens = helpOutput.split { !($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }
        return tokens.contains("--acp") ? ["--acp"] : AgentPresets.geminiFallbackArgs
    }

    /// The args to launch `def` with: Gemini's flag is probed with `--help`, every other agent keeps its args.
    public func launchArgs(for def: AgentDefinition, executable: URL) -> [String] {
        guard def.id == "gemini", def.isPreset else { return def.args }
        guard let help = helpRunner(executable) else { return def.args }
        return Self.geminiArgs(helpOutput: help)
    }

    @Sendable public static func runHelp(_ url: URL) -> String? {
        let p = Process()
        p.executableURL = url
        p.arguments = ["--help"]
        p.standardInput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        let pipe = Pipe()
        p.standardOutput = pipe
        let done = DispatchSemaphore(value: 0)
        p.terminationHandler = { _ in done.signal() }
        do { try p.run() } catch { return nil }
        final class Box: @unchecked Sendable { var data = Data() }
        let box = Box(), reader = DispatchGroup()
        reader.enter()
        DispatchQueue.global().async { box.data = pipe.fileHandleForReading.readDataToEndOfFile(); reader.leave() }
        if done.wait(timeout: .now() + 5) == .timedOut {
            p.terminate(); _ = done.wait(timeout: .now() + 1)
            return nil
        }
        reader.wait()
        return String(decoding: box.data, as: UTF8.self)
    }
}
