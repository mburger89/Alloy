@testable import AlloyCore
import Foundation
import Testing

@Suite struct ThemeLibraryTests {
    private func rgba(_ hex: String) -> ThemeRGBA { ThemeRGBA(hex: hex)! }

    private func entry(_ id: String, _ appearance: ThemeAppearance = .dark, base: String? = nil,
                       colors: [String: String] = [:], session: Int? = nil, builtIn: Bool = false) -> ThemeEntry {
        let list = session.map { n in (0..<n).map { ThemeRGBA(r: Double($0) / 20, g: 0, b: 0) } }
        let file = ThemeFile(name: id, appearance: appearance, base: base,
                             colors: colors.mapValues { rgba($0) }, sessionColors: list)
        return ThemeEntry(id: id, file: file, isBuiltIn: builtIn, url: nil)
    }

    private var testBuiltIns: [ThemeEntry] {
        [entry("alloy-dark", .dark, colors: ["accent": "#111111", "background": "#000000"], session: 8, builtIn: true),
         entry("alloy-light", .light, colors: ["accent": "#EEEEEE", "background": "#FFFFFF"], session: 8, builtIn: true)]
    }

    private func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("themes-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func write(_ text: String, _ name: String, in dir: URL) throws {
        try Data(text.utf8).write(to: dir.appendingPathComponent(name))
    }

    private func themeJSON(_ name: String, base: String? = nil, accent: String = "#102030",
                           appearance: String = "dark") -> String {
        let baseField = base.map { #","base":"\#($0)""# } ?? ""
        return #"{"name":"\#(name)","appearance":"\#(appearance)"\#(baseField),"colors":{"accent":"\#(accent)"}}"#
    }

    private func load(_ dir: URL, previous: ThemeLibrary? = nil) -> ThemeLibrary {
        ThemeLibrary.load(builtIns: testBuiltIns, userDirectory: dir, previous: previous)
    }

    @Test func userDirectoryIsUnderAlloy() {
        let url = ThemeLibrary.userDirectory(appSupport: URL(fileURLWithPath: "/x"))
        #expect(url.path == "/x/Alloy/Themes")
    }

    @Test func builtInsStartEmptyAndParse() {
        // Tasks 2 and 3 add themes; whatever is registered must parse and be marked built in.
        for theme in BuiltInThemes.all { #expect(theme.isBuiltIn) }
    }

    @Test func baseChainMerges() {
        let a = entry("user/a", colors: ["accent": "#AA0000", "background": "#0000AA"])
        let b = entry("user/b", base: "a", colors: ["accent": "#00BB00"])
        let c = entry("user/c", base: "b")
        let library = ThemeLibrary(builtIns: testBuiltIns, user: [a, b, c])
        let resolved = library.resolve("user/c")
        #expect(resolved?.colors["accent"]?.hex == "#00BB00")
        #expect(resolved?.colors["background"]?.hex == "#0000AA")
    }

    @Test func noBaseFallsBackByAppearance() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try write(themeJSON("D"), "d.json", in: dir)
        try write(themeJSON("L", appearance: "light"), "l.json", in: dir)
        let library = load(dir)
        #expect(library.resolve("user/d")?.colors["background"]?.hex == "#000000")
        #expect(library.resolve("user/d")?.colors["accent"]?.hex == "#102030")
        #expect(library.resolve("user/l")?.colors["background"]?.hex == "#FFFFFF")
        #expect(library.resolve("user/d")?.sessionColors.count == 8)
        #expect(library.errors.isEmpty)
    }

    @Test func sessionColorsComeFromNearestAncestor() {
        let a = entry("user/a", session: 6)
        let b = entry("user/b", base: "a")
        let c = entry("user/c", base: "b", session: 10)
        let library = ThemeLibrary(builtIns: testBuiltIns, user: [a, b, c])
        #expect(library.resolve("user/b")?.sessionColors.count == 6)
        #expect(library.resolve("user/c")?.sessionColors.count == 10)
    }

    @Test func unknownBaseFallsBackWithError() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try write(themeJSON("U", base: "nope"), "u.json", in: dir)
        let library = load(dir)
        #expect(library.resolve("user/u")?.colors["background"]?.hex == "#000000")
        #expect(library.errors.contains { $0.fileName == "u.json" })
    }

    @Test func baseThatFailedToParseSaysSo() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try write("{ not json", "b.json", in: dir)
        try write(themeJSON("C", base: "b"), "c.json", in: dir)
        let library = load(dir)
        let message = try #require(library.errors.first { $0.fileName == "c.json" }?.message)
        #expect(message.hasPrefix("Base \"b\" has an error"), "\(message)")
        #expect(library.errors.contains { $0.fileName == "b.json" })
    }

    @Test func baseCycleIsSkipped() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try write(themeJSON("X", base: "y"), "x.json", in: dir)
        try write(themeJSON("Y", base: "x"), "y.json", in: dir)
        try write(themeJSON("Self", base: "self"), "self.json", in: dir)
        let library = load(dir)
        #expect(library.resolve("user/x") == nil)
        #expect(library.resolve("user/y") == nil)
        #expect(library.resolve("user/self") == nil)
        #expect(Set(library.errors.map(\.fileName)) == ["x.json", "y.json", "self.json"])
        #expect(library.user.isEmpty)
    }

    @Test func deepChainIsReported() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try write(themeJSON("t0"), "t0.json", in: dir)
        for i in 1...9 { try write(themeJSON("t\(i)", base: "t\(i - 1)"), "t\(i).json", in: dir) }
        let library = load(dir)
        #expect(library.resolve("user/t8") != nil)   // 8 links is allowed
        #expect(library.resolve("user/t9") == nil)   // 9 links is not
        #expect(library.errors.contains { $0.fileName == "t9.json" })
    }

    @Test func userIdsAreNamespaced() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try write(themeJSON("Mine"), "alloy-dark.json", in: dir)
        let library = load(dir)
        #expect(library.entry("user/alloy-dark") != nil)
        #expect(library.entry("alloy-dark")?.isBuiltIn == true)
        #expect(library.entry("alloy-dark")?.file.name == "alloy-dark")
    }

    @Test func userBaseNamesBuiltInFirst() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try write(themeJSON("Shadow", accent: "#999999"), "alloy-dark.json", in: dir)
        try write(themeJSON("Child", base: "alloy-dark"), "child.json", in: dir)
        let library = load(dir)
        #expect(library.resolve("user/child")?.colors["background"]?.hex == "#000000")
        #expect(library.resolve("user/child")?.colors["accent"]?.hex == "#102030")
    }

    @Test func junkFilesAreSkippedOrReported() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try write("x", ".DS_Store", in: dir)
        try write("hello", "notes.txt", in: dir)
        try write(themeJSON("Hidden"), ".x.json", in: dir)
        try write(String(repeating: " ", count: 300 * 1024), "big.json", in: dir)
        try write("[]", "arr.json", in: dir)
        try write(themeJSON("Good"), "good.json", in: dir)
        let library = load(dir)
        #expect(library.user.map(\.id) == ["user/good"])
        #expect(Set(library.errors.map(\.fileName)) == ["big.json", "arr.json"])
        #expect(library.errors.first { $0.fileName == "big.json" }?.message.contains("large") == true)
    }

    @Test func brokenFileKeepsPreviousGoodVersion() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try write(themeJSON("T", accent: "#ABCDEF"), "t.json", in: dir)
        let first = load(dir)
        try write("{", "t.json", in: dir)
        let second = load(dir, previous: first)
        #expect(second.user.map(\.id) == ["user/t"])
        #expect(second.resolve("user/t")?.colors["accent"]?.hex == "#ABCDEF")
        #expect(second.errors.contains { $0.fileName == "t.json" })
        let third = load(dir)   // no previous: the broken theme is simply absent
        #expect(third.user.isEmpty)
    }

    @Test func missingFolderIsEmptyNotAnError() {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("nope-\(UUID().uuidString)")
        let library = load(dir)
        #expect(library.user.isEmpty)
        #expect(library.errors.isEmpty)
    }

    @Test func allIsBuiltInsThenUserSortedByName() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try write(themeJSON("Zed"), "a.json", in: dir)
        try write(themeJSON("alpha"), "z.json", in: dir)
        let library = load(dir)
        #expect(library.all.map(\.id) == ["alloy-dark", "alloy-light", "user/z", "user/a"])
    }

    @Test func symlinkedThemeIsFollowed() throws {
        let dir = try tempDir()
        let outside = try tempDir()
        defer {
            try? FileManager.default.removeItem(at: dir)
            try? FileManager.default.removeItem(at: outside)
        }
        try write(themeJSON("Linked"), "real.json", in: outside)
        try FileManager.default.createSymbolicLink(
            at: dir.appendingPathComponent("linked.json"), withDestinationURL: outside.appendingPathComponent("real.json"))
        let library = load(dir)
        #expect(library.user.map(\.id) == ["user/linked"])
        #expect(library.errors.isEmpty)
    }

    @Test func danglingAndDirectoryLinksAreReported() throws {
        let dir = try tempDir()
        let outside = try tempDir()
        defer {
            try? FileManager.default.removeItem(at: dir)
            try? FileManager.default.removeItem(at: outside)
        }
        let fm = FileManager.default
        try fm.createSymbolicLink(at: dir.appendingPathComponent("dangling.json"),
                                  withDestinationURL: outside.appendingPathComponent("missing.json"))
        try fm.createSymbolicLink(at: dir.appendingPathComponent("dirlink.json"), withDestinationURL: outside)
        try fm.createDirectory(at: dir.appendingPathComponent("folder.json"), withIntermediateDirectories: false)
        let library = load(dir)
        #expect(library.user.isEmpty)
        #expect(Set(library.errors.map(\.fileName)) == ["dangling.json", "dirlink.json"])
        for error in library.errors { #expect(!error.message.isEmpty && !error.message.contains("\n")) }
    }

    @Test func oversizeSymlinkTargetIsReported() throws {
        let dir = try tempDir()
        let outside = try tempDir()
        defer {
            try? FileManager.default.removeItem(at: dir)
            try? FileManager.default.removeItem(at: outside)
        }
        try write(String(repeating: " ", count: 300 * 1024), "big.json", in: outside)
        try FileManager.default.createSymbolicLink(
            at: dir.appendingPathComponent("biglink.json"), withDestinationURL: outside.appendingPathComponent("big.json"))
        let library = load(dir)
        #expect(library.user.isEmpty)
        #expect(library.errors.map(\.fileName) == ["biglink.json"])
    }

    @Test func deletedFileIsNotKept() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try write(themeJSON("T"), "t.json", in: dir)
        let first = load(dir)
        #expect(first.user.count == 1)
        try FileManager.default.removeItem(at: dir.appendingPathComponent("t.json"))
        let second = load(dir, previous: first)
        #expect(second.user.isEmpty)
        #expect(second.errors.isEmpty)
    }

    @Test func duplicateIdsKeepFirstAndReportRest() throws {
        // `a.JSON` and `a.json` share the id `user/a`. A case-insensitive volume cannot hold both names in one
        // folder, so they live in two folders and the listing hands the loader both.
        let upperDir = try tempDir(), lowerDir = try tempDir()
        defer {
            try? FileManager.default.removeItem(at: upperDir)
            try? FileManager.default.removeItem(at: lowerDir)
        }
        try write(themeJSON("Upper"), "a.JSON", in: upperDir)
        try write(themeJSON("Lower"), "a.json", in: lowerDir)
        let files = [lowerDir.appendingPathComponent("a.json"), upperDir.appendingPathComponent("a.JSON")]
        let library = ThemeLibrary.load(builtIns: testBuiltIns, userDirectory: upperDir, previous: nil,
                                        listing: { _ in files })
        #expect(library.user.map(\.id) == ["user/a"])
        #expect(library.user.first?.file.name == "Upper")   // "a.JSON" sorts before "a.json"
        #expect(library.errors.map(\.fileName) == ["a.json"])
    }

    @Test func everyBuiltInSourceParses() {
        #expect(BuiltInThemes.all.count == BuiltInThemes.sources.count)
        #expect(Set(BuiltInThemes.all.map(\.id)).count == BuiltInThemes.all.count)
    }
}
