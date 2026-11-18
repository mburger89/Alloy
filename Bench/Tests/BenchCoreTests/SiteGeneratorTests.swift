import Testing
import Foundation
@testable import BenchCore

@Suite struct SiteGeneratorTests {
    @Test func writesTheWholeSiteAndKeepsAppcast() throws {
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent("sitegen-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: base) }
        let pub = base.appendingPathComponent("published"), out = base.appendingPathComponent("site")
        try fm.createDirectory(at: pub, withIntermediateDirectories: true)
        try fm.createDirectory(at: out, withIntermediateDirectories: true)
        let r = LandingPageTests.run()
        let enc = JSONEncoder()
        var e = SitePageTests.entry(r); e.stem = "run0"
        var idx = PublishedIndex(); idx.upsert(e)
        try enc.encode(idx).write(to: pub.appendingPathComponent("index.json"))
        try enc.encode(r).write(to: pub.appendingPathComponent("run0.json"))
        let appcast = Data("<rss>keep me</rss>".utf8)
        try appcast.write(to: out.appendingPathComponent("appcast.xml"))
        let svg = base.appendingPathComponent("icon.svg"); try Data("<svg/>".utf8).write(to: svg)

        for _ in 0..<2 {   // regeneration is idempotent
            #expect(try SiteGenerator.generate(publishedDir: pub, out: out, iconSVG: svg) == 1)
        }
        for f in ["index.html", "benchmarks/index.html", "data/run0.json", "assets/icon.svg"] {
            #expect(fm.fileExists(atPath: out.appendingPathComponent(f).path), "missing \(f)")
        }
        #expect(try Data(contentsOf: out.appendingPathComponent("appcast.xml")) == appcast)
        let landing = try String(contentsOf: out.appendingPathComponent("index.html"), encoding: .utf8)
        #expect(landing.contains("Fast. Native. Yours."))
        #expect(try String(contentsOf: out.appendingPathComponent("benchmarks/index.html"), encoding: .utf8).contains("Alloy benchmarks"))
    }
}
