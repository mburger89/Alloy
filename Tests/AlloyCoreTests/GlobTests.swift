import Testing

@testable import AlloyCore

@Suite struct GlobTests {
    @Test func doubleStarExtension() {
        let g = GlobFilter(include: "**/*.swift", exclude: "", extraExclude: [])
        #expect(g.allows("a.swift"))
        #expect(g.allows("Sources/A/b.swift"))
        #expect(!g.allows("Sources/A/b.md"))
    }

    @Test func directoryPrefix() {
        let g = GlobFilter(include: "Sources/**", exclude: "", extraExclude: [])
        #expect(g.allows("Sources/a.swift"))
        #expect(g.allows("Sources/x/y/z.txt"))
        #expect(!g.allows("Tests/a.swift"))
    }

    @Test func bareNameMeansAnywhere() {
        let g = GlobFilter(include: "", exclude: "build", extraExclude: [])
        #expect(!g.allows("build/x.o"))
        #expect(!g.allows("a/b/build/x.o"))
        #expect(!g.allows("pkg/build"))
        #expect(g.allows("rebuild/x.o"))
        #expect(g.allows("src/main.swift"))
    }

    @Test func commaListsWithSpaces() {
        let g = GlobFilter(include: "**/*.swift ,  **/*.md", exclude: "", extraExclude: [])
        #expect(g.allows("a.swift"))
        #expect(g.allows("docs/a.md"))
        #expect(!g.allows("a.txt"))
    }

    @Test func extraExcludeAppended() {
        let g = GlobFilter(include: "", exclude: "node_modules", extraExclude: ["*.log", ".git"])
        #expect(!g.allows("node_modules/a.js"))
        #expect(!g.allows("x/y.log"))
        #expect(!g.allows(".git/HEAD"))
        #expect(g.allows("x/y.txt"))
    }

    @Test func emptyIncludeAllowsAll() {
        let g = GlobFilter(include: "", exclude: "", extraExclude: [])
        #expect(g.allows("anything/at/all"))
        #expect(g.allows(".hidden"))
    }

    @Test func excludeWinsOverInclude() {
        let g = GlobFilter(include: "**/*.swift", exclude: "Generated/**", extraExclude: [])
        #expect(g.allows("Sources/a.swift"))
        #expect(!g.allows("Generated/a.swift"))
    }

    @Test func dotfilesMatchStar() {
        let g = GlobFilter(include: "*", exclude: "", extraExclude: [])
        #expect(g.allows(".env"))
        let h = GlobFilter(include: "**/*.json", exclude: "", extraExclude: [])
        #expect(h.allows(".vscode/settings.json"))
    }

    @Test func trailingSlashDirectory() {
        let g = GlobFilter(include: "", exclude: "dist/", extraExclude: [])
        #expect(!g.allows("dist/a.js"))
        #expect(g.allows("src/a.js"))
    }
}
