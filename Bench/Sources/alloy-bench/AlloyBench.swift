import ArgumentParser
import Foundation
import BenchCore
import BenchScenarios

@main
struct AlloyBench: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "alloy-bench",
        abstract: "Benchmark Zed, Delta and Alloy with identical scenarios.")

    @Option(help: "Comma-separated: zed,delta,alloy (default: zed,delta; plus alloy when --alloy-build is given)") var apps: String?
    @Option(help: "Comma-separated metrics (default: all)") var metrics: String?
    @Option(help: "Override the number of runs per metric") var runs: Int?
    @Flag(help: "Purge disk caches before each startup run (needs passwordless sudo)") var cold = false
    @Option(help: "Alloy repo root (binary at <dir>/.build/release/Alloy)") var alloyBuild: String?
    @Option(help: "Output directory") var out: String = "Bench/results"

    func run() async throws {
        let targets: [TargetApp]
        let selected: [Metric]
        do {
            targets = try CLIArguments.resolveApps(apps, alloyBuild: alloyBuild)
            selected = try CLIArguments.resolveMetrics(metrics)
        } catch { throw ValidationError("\(error)") }
        if let fail = Preflight.check(apps: targets) {
            FileHandle.standardError.write(Data((fail.message + "\n").utf8))
            throw ExitCode(fail.code)
        }
        SignalGuard.install()
        var refusal: String?
        let result: RunResult
        do {
            result = try await Runner.run(apps: targets, metrics: selected, corpus: .default, runsOverride: runs, cold: cold)
        } catch let e as Runner.CoverRefused {
            result = e.partial; refusal = e.message   // report what was measured, then exit 4
        }
        try FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)
        let stem = out + "/" + Report.fileStem(result)
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(result).write(to: URL(fileURLWithPath: stem + ".json"))
        let md = Report.markdown(result)
        try md.write(toFile: stem + ".md", atomically: true, encoding: .utf8)
        print(md)
        print("wrote \(stem).json and \(stem).md")
        for w in result.notes where w.hasPrefix("leftover process:") {
            FileHandle.standardError.write(Data(("warning: " + w + "\n").utf8))
        }
        if let refusal {
            FileHandle.standardError.write(Data((refusal + "\n").utf8))
            throw ExitCode(Preflight.coverExitCode)
        }
    }
}

