import ArgumentParser
import Foundation
import BenchCore

struct HotspotsCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "hotspots",
        abstract: "Summarise an Instruments trace (Time Profiler or Allocations) as a short text list.")

    @Argument(help: "A .trace recorded by `alloy-bench run --trace`") var trace: String
    @Option(help: "Rows per ranking") var top = 25
    @Option(help: .hidden) var xcrun = "/usr/bin/xcrun"

    func validate() throws {
        guard top >= 1 else { throw ValidationError("--top must be at least 1") }
    }

    func run() throws {
        let text: String
        do { text = try Hotspots.report(trace: trace, top: top, executable: xcrun) }
        catch {
            FileHandle.standardError.write(Data("\(error)\n".utf8))
            throw ExitCode(1)
        }
        print(text, terminator: "")
        let path = Hotspots.markdownPath(forTrace: trace)
        do { try text.write(toFile: path, atomically: true, encoding: .utf8) }
        catch { FileHandle.standardError.write(Data("warning: could not write \(path): \(error.localizedDescription)\n".utf8)) }
    }
}
