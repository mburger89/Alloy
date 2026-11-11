@testable import AlloyCore
import Foundation
import Testing

@Suite struct ThemeStoreTests {
    private func sample(_ name: String = "X", accent: String = "#102030") -> ThemeFile {
        ThemeFile(name: name, appearance: .dark, base: "dracula", author: "me", credit: "them",
                  colors: ["accent": ThemeRGBA(hex: accent)!, "background": ThemeRGBA(hex: "#00000080")!],
                  sessionColors: (0..<6).map { ThemeRGBA(hex: "#\($0)0\($0)0A0")! })
    }

    private func tempSupport() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("store-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private let builtIns = BuiltInThemes.all

    @Test func encodedRoundTrips() throws {
        let file = sample("Round")
        #expect(try ThemeFile.parse(try file.encoded()) == file)
        let bare = ThemeFile(name: "Bare", appearance: .light)
        #expect(try ThemeFile.parse(try bare.encoded()) == bare)
        #expect(String(decoding: try file.encoded(), as: UTF8.self).contains("#102030"))
    }

    @Test func namesAreSlugsInsideTheFolder() throws {
        #expect(ThemeStore.slug("../../x") == "x")
        #expect(ThemeStore.slug("Warm Paper!") == "warm-paper")
        #expect(ThemeStore.slug("") == "theme")
        #expect(ThemeStore.slug("🔥") == "theme")
        #expect(ThemeStore.slug(String(repeating: "a", count: 100)).count == 64)
        let support = try tempSupport()
        let store = ThemeStore(appSupport: support)
        let session = UUID()
        for name in ["../../x", "Warm Paper!", "", "🔥", "a/b\\c"] {
            let saved = try store.save(sample(), name: name, session: session, builtIns: builtIns)
            #expect(saved.url.deletingLastPathComponent().standardizedFileURL.path
                    == ThemeLibrary.userDirectory(appSupport: support).standardizedFileURL.path)
        }
    }

    @Test func clashesAreRenamed() throws {
        let support = try tempSupport()
        let store = ThemeStore(appSupport: support)
        let a = UUID(), b = UUID()
        let drac = try store.save(sample(), name: "Dracula", session: a, builtIns: builtIns)
        #expect(drac.name == "Dracula 2")
        #expect(drac.id == "user/dracula-2")
        #expect(drac.renamed)
        #expect(try ThemeFile.parse(Data(contentsOf: drac.url)).name == "Dracula 2")

        let dir = ThemeLibrary.userDirectory(appSupport: support)
        let paper = dir.appendingPathComponent("paper.json")
        try Data(#"{"name":"Paper","appearance":"light"}"#.utf8).write(to: paper)
        let before = try Data(contentsOf: paper)
        let p2 = try store.save(sample(), name: "Paper", session: a, builtIns: builtIns)
        #expect(p2.name == "Paper 2")
        #expect(try Data(contentsOf: paper) == before)

        _ = try store.save(sample(), name: "Mine", session: a, builtIns: builtIns)
        let mine = try store.save(sample(), name: "Mine", session: b, builtIns: builtIns)
        #expect(mine.name == "Mine 2")
        #expect(!store.owns("user/mine", session: b))
        #expect(store.owns("user/mine-2", session: b))
    }

    @Test func ownerMayOverwriteOwnFile() throws {
        let store = ThemeStore(appSupport: try tempSupport())
        let a = UUID()
        let first = try store.save(sample(accent: "#111111"), name: "Mine", session: a, builtIns: builtIns)
        let second = try store.save(sample(accent: "#222222"), name: "Mine", session: a, builtIns: builtIns)
        #expect(first.id == "user/mine" && second.id == "user/mine")
        #expect(!first.renamed && !second.renamed)
        #expect(String(decoding: try Data(contentsOf: second.url), as: UTF8.self).contains("#222222"))
    }

    @Test func handEditedFileIsNoLongerOwned() throws {
        let store = ThemeStore(appSupport: try tempSupport())
        let a = UUID()
        let first = try store.save(sample(), name: "Mine", session: a, builtIns: builtIns)
        var bytes = try Data(contentsOf: first.url)
        bytes.append(UInt8(ascii: " "))
        try bytes.write(to: first.url)
        #expect(!store.owns("user/mine", session: a))
        #expect(try store.save(sample(), name: "Mine", session: a, builtIns: builtIns).name == "Mine 2")
    }

    @Test func ownersSurviveANewStore() throws {
        let support = try tempSupport()
        let a = UUID()
        _ = try ThemeStore(appSupport: support).save(sample(), name: "Mine", session: a, builtIns: builtIns)
        let fresh = ThemeStore(appSupport: support)
        #expect(fresh.owns("user/mine", session: a))
        #expect(try fresh.save(sample(), name: "Mine", session: a, builtIns: builtIns).id == "user/mine")
    }

    @Test func corruptOwnersFileOwnsNothing() throws {
        let support = try tempSupport()
        let a = UUID()
        _ = try ThemeStore(appSupport: support).save(sample(), name: "Mine", session: a, builtIns: builtIns)
        try Data("garbage".utf8).write(to: support.appendingPathComponent("Alloy/theme-owners.json"))
        #expect(!ThemeStore(appSupport: support).owns("user/mine", session: a))
    }

    @Test func concurrentSavesOfOneNameStayDistinct() async throws {
        for _ in 0..<5 {
            let support = try tempSupport()
            let sessions = (0..<4).map { _ in UUID() }
            let saved = try await withThrowingTaskGroup(of: SavedTheme.self) { group in
                for (i, session) in sessions.enumerated() {
                    group.addTask {
                        try ThemeStore(appSupport: support).save(
                            sample(accent: "#10\(i)0\(i)0"), name: "Race", session: session, builtIns: BuiltInThemes.all)
                    }
                }
                return try await group.reduce(into: []) { $0.append($1) }
            }
            #expect(Set(saved.map(\.id)).count == 4)
            let store = ThemeStore(appSupport: support)
            for item in saved {
                let parsed = try ThemeFile.parse(Data(contentsOf: item.url))
                #expect(parsed.name == item.name)
            }
            for session in sessions {
                #expect(saved.contains { store.owns($0.id, session: session) })
            }
        }
    }

    @Test func longNamesGetDistinctStems() throws {
        let store = ThemeStore(appSupport: try tempSupport())
        let a = UUID(), b = UUID()
        let long = String(repeating: "a", count: 100)
        let first = try store.save(sample(), name: long, session: a, builtIns: builtIns)
        let second = try store.save(sample(), name: long, session: b, builtIns: builtIns)
        let third = try store.save(sample(), name: long, session: b, builtIns: builtIns)
        #expect(first.id != second.id)
        #expect(second.renamed && second.id == third.id)
        #expect(second.id.count - 5 <= 64)
        #expect(store.owns(first.id, session: a))
    }
}
