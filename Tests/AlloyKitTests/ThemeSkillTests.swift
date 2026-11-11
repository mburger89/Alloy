import AlloyCore
@testable import AlloyKit
import Foundation
import Testing

@Suite struct ThemeSkillTests {
    private static let folder = "/tmp/example/Alloy/Themes"

    @Test func skillMarkdownHasFrontmatterBothModesAndTheFolder() throws {
        let text = try #require(ThemeSkill.files(themesFolder: Self.folder)["SKILL.md"])
        #expect(text.hasPrefix("---\nname: alloy-theme\ndescription: "))
        let description = try #require(text.split(separator: "\n").dropFirst().first { $0.hasPrefix("description: ") })
        #expect(description.contains("Alloy") && description.contains("theme"))
        let frontmatter = text.components(separatedBy: "\n---\n")[0]
        #expect(frontmatter.split(separator: "\n").count == 3, "frontmatter is name and a one-line description")
        #expect(text.contains(ThemeGuidance.text), "the guidance verbatim")
        #expect(text.contains("## In an Alloy theme session") && text.contains("## Anywhere else"))
        #expect(text.contains(Self.folder + "/<slug>.json"))
        #expect(text.contains("Never overwrite an existing file") && text.contains("\"<name> 2\""))
        #expect(text.contains("4.5:1") && text.contains("3:1") && text.contains("WCAG 2.1"))
        #expect(text.contains("settings.json"), "says never to edit it")
        #expect(!text.contains("Claude Code"))
        #expect(!text.contains("/Users/"))
    }

    @Test func everyFileAvoidsBrandingAndPersonalPaths() {
        for (path, text) in ThemeSkill.files(themesFolder: ThemeSkill.docsThemesFolder) {
            #expect(!text.contains("Claude Code"), "\(path)")
            #expect(!text.contains("/Users/"), "\(path)")
        }
    }

    @Test func slotsReferenceListsEveryDefinedSlot() throws {
        let text = try #require(ThemeSkill.files(themesFolder: Self.folder)["reference/slots.md"])
        for slot in ThemeSlots.all {
            #expect(text.contains("- `\(slot.name)`: \(slot.purpose)"), "\(slot.name)")
        }
    }

    @Test func sixReferenceThemesResolveToTheBuiltIns() throws {
        let files = ThemeSkill.files(themesFolder: Self.folder)
        let library = ThemeLibrary(builtIns: BuiltInThemes.all)
        let ids = ["dracula", "alloy-dark", "alloy-light", "solarized-dark", "solarized-light", "one-dark"]
        #expect(Set(files.keys) == Set(["SKILL.md", "reference/slots.md"] + ids.map { "reference/\($0).json" }))
        for id in ids {
            let text = try #require(files["reference/\(id).json"])
            let file = try ThemeFile.parse(Data(text.utf8))
            let expected = try #require(library.resolve(id))
            #expect(file.base == nil)
            var scratch = ThemeLibrary(builtIns: BuiltInThemes.all)
            scratch.user = [ThemeEntry(id: "user/ref", file: file, isBuiltIn: false)]
            let got = try #require(scratch.resolve("user/ref"))
            #expect(got.colors == expected.colors, "\(id)")
            #expect(got.sessionColors == expected.sessionColors, "\(id)")
            #expect(got.appearance == expected.appearance && file.name == expected.name)
            for slot in ThemeSlots.all { #expect(file.colors[slot.name] != nil, "\(id) lacks \(slot.name)") }
        }
    }

    /// The tracked hand-install copy equals the generated skill. To regenerate it after changing `ThemeSkill`:
    /// `ALLOY_WRITE_SKILL_DOCS=1 swift test --filter docsCopyMatchesGeneratedSkill`
    @Test func docsCopyMatchesGeneratedSkill() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("docs/skills/alloy-theme")
        let generated = ThemeSkill.files(themesFolder: ThemeSkill.docsThemesFolder)
        if ProcessInfo.processInfo.environment["ALLOY_WRITE_SKILL_DOCS"] == "1" {
            for (path, text) in generated {
                let url = root.appendingPathComponent(path)
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data(text.utf8).write(to: url)
            }
        }
        var tracked: [String: String] = [:]
        let enumerator = try #require(FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey]))
        for case let url as URL in enumerator where (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true {
            tracked[String(url.path.dropFirst(root.path.count + 1))] = try String(contentsOf: url, encoding: .utf8)
        }
        #expect(Set(tracked.keys) == Set(generated.keys), "file set differs; regenerate (see the comment above)")
        for (path, text) in generated { #expect(tracked[path] == text, "\(path) differs; regenerate (see the comment above)") }
    }

    @Test func frontmatterValuesAreYAMLSafe() throws {
        let text = try #require(ThemeSkill.files(themesFolder: Self.folder)["SKILL.md"])
        let front = text.components(separatedBy: "\n---\n")[0].split(separator: "\n").dropFirst()
        #expect(front.count == 2)
        for line in front {
            let parts = line.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            #expect(parts.count == 2, "\(line)")
            let value = parts[1]
            let quoted = value.count >= 2 && value.hasPrefix("\"") && value.hasSuffix("\"")
                && !value.dropFirst().dropLast().contains("\"") && !value.contains("\\")
            let plain = !value.contains(": ") && !value.contains(" #") && !value.contains("\"") && !value.contains("'")
                && !"-?:,[]{}#&*!|>%@`".contains(value.first ?? "a")
            #expect(quoted || plain, "unsafe YAML value: \(line)")
        }
    }

    @Test func contrastListCoversEveryRule() throws {
        let text = try #require(ThemeSkill.files(themesFolder: Self.folder)["SKILL.md"])
        for rule in ThemeContrast.rules {
            for fg in rule.foregrounds {
                for bg in rule.backgrounds {
                    let background = "`" + bg.joined(separator: "` over `") + "`"
                    #expect(text.contains("`\(fg)`") && text.contains(background), "\(fg) on \(bg)")
                }
            }
        }
        for needle in ["`surface` over `codeSelectionFill`", "`surfaceSecondary` over `pickerThumb`", "0.648", "0.588",
                       "textPrimary at alpha 0.18"] {
            #expect(text.contains(needle), "\(needle)")
        }
    }

    @Test func namingGuidance() throws {
        let text = try #require(ThemeSkill.files(themesFolder: Self.folder)["SKILL.md"])
        #expect(text.contains("never with a built-in's name"))
        #expect(text.contains("Dracula") && text.contains("One Dark"))
        #expect(text.contains("file name without `.json`"))
    }
}
