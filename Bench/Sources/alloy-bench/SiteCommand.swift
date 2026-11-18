import ArgumentParser
import Foundation
import BenchCore

struct SiteCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "site",
        abstract: "Render the landing page (/), the results page (/benchmarks/) and data/ from the published results.")

    @Option(help: "Published results directory (default: Bench/published in the repository)") var published: String?
    @Option(help: "Output directory for index.html, benchmarks/ and data/ (default: Bench/site in the repository)") var out: String?

    func run() throws {
        let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let src = try RepoPaths.resolve(published, fallback: "Bench/published", cwd: cwd)
        let dest = try RepoPaths.resolve(out, fallback: "Bench/site", cwd: cwd)
        // Keep the vector icon in step with the app's source icon when generating inside the repository.
        let icon = RepoPaths.root(from: dest)?.appendingPathComponent("Packaging/icon.svg")
        let n = try SiteGenerator.generate(publishedDir: src, out: dest, iconSVG: icon)
        print("wrote \(dest.path)/index.html and benchmarks/index.html (\(n) runs)")
    }
}
