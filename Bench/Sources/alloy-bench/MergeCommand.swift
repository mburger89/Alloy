import ArgumentParser
import Foundation
import BenchCore

struct MergeCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "merge",
        abstract: "Combine two runs: apps re-measured in the override run replace those of the base run.")

    @Argument(help: "Base result JSON") var base: String
    @Argument(help: "Override result JSON (re-measured apps)") var override: String
    @Option(help: "Comma-separated app ids taken from the override (default: every app in it)") var apps: String?
    @Flag(help: "Drop the first startup sample of every app (retroactive warm-up launch)") var dropFirstStartup = false
    @Option(help: "Output file for the merged result JSON") var out: String

    func run() throws {
        let dec = JSONDecoder()
        let b = try dec.decode(RunResult.self, from: Data(contentsOf: URL(fileURLWithPath: base)))
        let o = try dec.decode(RunResult.self, from: Data(contentsOf: URL(fileURLWithPath: override)))
        let ids = apps.map { $0.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) } }
        let merged: RunResult
        do { merged = try ResultMerger.merge(base: b, override: o, apps: ids, dropFirstStartup: dropFirstStartup) }
        catch {
            FileHandle.standardError.write(Data("\(error)\n".utf8))
            throw ExitCode(6)
        }
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(merged).write(to: URL(fileURLWithPath: out))
        print("merged \(Report.fileStem(b)) + \(Report.fileStem(o)) -> \(out)")
    }
}
