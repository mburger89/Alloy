import Foundation

/// Writes the whole site: landing page, `benchmarks/index.html`, `data/` and `assets/icon.svg`.
/// Files it does not own (such as `appcast.xml`, written by the release script) are never touched.
public enum SiteGenerator {
    /// Returns the number of runs rendered. `iconSVG` is copied to `assets/icon.svg` when it exists.
    @discardableResult
    public static func generate(publishedDir src: URL, out dest: URL, iconSVG: URL?) throws -> Int {
        let (index, runs) = try SitePage.load(publishedDir: src)
        let data = dest.appendingPathComponent("data")
        let bench = dest.appendingPathComponent("benchmarks")
        let assets = dest.appendingPathComponent("assets")
        let fm = FileManager.default
        for d in [data, bench, assets] { try fm.createDirectory(at: d, withIntermediateDirectories: true) }
        for e in index.runs {
            let target = data.appendingPathComponent(e.stem + ".json")
            try? fm.removeItem(at: target)
            try fm.copyItem(at: src.appendingPathComponent(e.stem + ".json"), to: target)
        }
        if let icon = iconSVG, fm.fileExists(atPath: icon.path) {
            let target = assets.appendingPathComponent("icon.svg")
            try? fm.removeItem(at: target)
            try fm.copyItem(at: icon, to: target)
        }
        var content = LandingContent()
        content.assets = LandingPage.assetNames(in: assets)
        try Data(LandingPage.render(index: index, runs: runs, content: content).utf8).write(to: dest.appendingPathComponent("index.html"))
        try Data(SitePage.render(index: index, runs: runs).utf8).write(to: bench.appendingPathComponent("index.html"))
        return runs.count
    }
}
