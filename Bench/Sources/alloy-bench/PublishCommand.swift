import ArgumentParser
import Foundation
import BenchCore

struct PublishCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "publish",
        abstract: "Scrub a result of private paths and add it to the published index.")

    @Argument(help: "Result JSON written by `alloy-bench run`") var result: String
    @Option(help: "Published results directory (default: Bench/published in the repository)") var to: String?
    @Flag(help: "Publish a run that lacks Alloy or Zed results") var allowPartial = false

    func run() throws {
        let data = try Data(contentsOf: URL(fileURLWithPath: result))
        let decoded = try JSONDecoder().decode(RunResult.self, from: data)
        let scrubber = Scrubber(home: NSHomeDirectory(), userName: NSUserName())
        let prepared: (json: Data, entry: PublishedEntry)
        do { prepared = try Publisher.prepare(decoded, scrubber: scrubber, allowPartial: allowPartial) }
        catch {
            FileHandle.standardError.write(Data("\(error)\n".utf8))
            throw ExitCode(6)
        }
        let dir = try RepoPaths.resolve(to, fallback: "Bench/published",
                                        cwd: URL(fileURLWithPath: FileManager.default.currentDirectoryPath))
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let indexURL = dir.appendingPathComponent("index.json")
        var index = PublishedIndex()
        if let old = try? Data(contentsOf: indexURL) { index = try JSONDecoder().decode(PublishedIndex.self, from: old) }
        index.upsert(prepared.entry)
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try prepared.json.write(to: dir.appendingPathComponent(prepared.entry.stem + ".json"))
        try enc.encode(index).write(to: indexURL)
        print("published \(prepared.entry.stem) (\(index.runs.count) runs in index)")
    }
}
