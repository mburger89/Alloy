import ArgumentParser
import Foundation
import BenchCore

struct SiteCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "site",
        abstract: "Render the static results page from the published results.")

    @Option(help: "Published results directory (default: Bench/published in the repository)") var published: String?
    @Option(help: "Output directory for index.html and data/ (default: Bench/site in the repository)") var out: String?

    func run() throws {
        let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let src = try RepoPaths.resolve(published, fallback: "Bench/published", cwd: cwd)
        let (index, runs) = try SitePage.load(publishedDir: src)
        let dest = try RepoPaths.resolve(out, fallback: "Bench/site", cwd: cwd)
        let data = dest.appendingPathComponent("data")
        let fm = FileManager.default
        try fm.createDirectory(at: data, withIntermediateDirectories: true)
        for e in index.runs {
            let target = data.appendingPathComponent(e.stem + ".json")
            try? fm.removeItem(at: target)
            try fm.copyItem(at: src.appendingPathComponent(e.stem + ".json"), to: target)
        }
        try Data(SitePage.render(index: index, runs: runs).utf8).write(to: dest.appendingPathComponent("index.html"))
        print("wrote \(dest.path)/index.html (\(runs.count) runs)")
    }
}
