import AlloyCore
import Foundation
import Testing

/// Every test uses a temporary home; nothing here may touch the real `~/.claude`.
@Suite struct ThemeSkillInstallerTests {
    private func tempHome() throws -> URL {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("alloy-skill-\(UUID().uuidString)")
            .resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        return home
    }

    private let files = ["SKILL.md": "# skill\n", "reference/slots.md": "slots\n", "reference/dracula.json": "{}\n"]

    private func allFiles(under root: URL) -> [String] {
        let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey])
        return (e?.compactMap { $0 as? URL } ?? []).filter { (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true }
            .map { String($0.resolvingSymlinksInPath().path.dropFirst(root.resolvingSymlinksInPath().path.count + 1)) }.sorted()
    }

    @Test func directoryIsUnderTheInjectedHome() throws {
        let home = try tempHome()
        defer { try? FileManager.default.removeItem(at: home) }
        #expect(ThemeSkillInstaller(home: home).directory.path == home.path + "/.claude/skills/alloy-theme")
    }

    @Test func notInstalledThenCurrentAfterInstall() throws {
        let home = try tempHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let installer = ThemeSkillInstaller(home: home)
        #expect(installer.status(files: files) == .notInstalled)
        try installer.install(files: files)
        #expect(installer.status(files: files) == .current)
        for (path, text) in files {
            #expect(try String(contentsOf: installer.directory.appendingPathComponent(path), encoding: .utf8) == text)
        }
    }

    @Test func editedOrMissingFileIsDifferentAndInstallRestores() throws {
        let home = try tempHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let installer = ThemeSkillInstaller(home: home)
        try installer.install(files: files)
        try "edited".write(to: installer.directory.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
        #expect(installer.status(files: files) == .different)
        try installer.install(files: files)
        #expect(installer.status(files: files) == .current)
        try FileManager.default.removeItem(at: installer.directory.appendingPathComponent("reference/slots.md"))
        #expect(installer.status(files: files) == .different)
        var newer = files
        newer["SKILL.md"] = "# newer\n"
        try installer.install(files: files)
        #expect(installer.status(files: newer) == .different)
    }

    @Test func extraUserFilesAreKept() throws {
        let home = try tempHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let installer = ThemeSkillInstaller(home: home)
        try installer.install(files: files)
        let extra = installer.directory.appendingPathComponent("notes.txt")
        try "mine".write(to: extra, atomically: true, encoding: .utf8)
        try installer.install(files: files)
        #expect(try String(contentsOf: extra, encoding: .utf8) == "mine")
        #expect(installer.status(files: files) == .current)
    }

    @Test func unsafePathsAreRefusedAndNothingIsWritten() throws {
        let home = try tempHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let installer = ThemeSkillInstaller(home: home)
        for bad in ["../escape.md", "a/../../escape.md", "/abs.md", "", "a//b.md", "./x.md", ".."] {
            #expect(throws: ThemeSkillInstallError.unsafePath(bad)) {
                try installer.install(files: ["SKILL.md": "ok", bad: "bad"])
            }
        }
        #expect(allFiles(under: home).isEmpty, "a refused install writes nothing, not even the valid files")
        #expect(installer.status(files: ["../x": "y"]) == .different)
    }

    @Test func writesOnlyInsideTheSkillDirectory() throws {
        let home = try tempHome()
        defer { try? FileManager.default.removeItem(at: home) }
        try "keep".write(to: home.appendingPathComponent("sentinel.txt"), atomically: true, encoding: .utf8)
        try ThemeSkillInstaller(home: home).install(files: files)
        let written = allFiles(under: home)
        let inside = written.filter { $0.hasPrefix(".claude/skills/alloy-theme/") }
        #expect(inside.count == files.count, "\(written)")
        #expect(Set(written).subtracting(inside) == ["sentinel.txt"], "\(written)")
        #expect(try String(contentsOf: home.appendingPathComponent("sentinel.txt"), encoding: .utf8) == "keep")
    }

    @Test func installExpectingNotInstalledRefusesWhenFilesAppearedMeanwhile() throws {
        let home = try tempHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let installer = ThemeSkillInstaller(home: home)
        // Someone copied a different SKILL.md in after the status was read.
        try FileManager.default.createDirectory(at: installer.directory, withIntermediateDirectories: true)
        let theirs = installer.directory.appendingPathComponent("SKILL.md")
        try "theirs".write(to: theirs, atomically: true, encoding: .utf8)
        #expect(try installer.install(files: files, expecting: .notInstalled) == .different)
        #expect(try String(contentsOf: theirs, encoding: .utf8) == "theirs", "nothing was written")
        #expect(!FileManager.default.fileExists(atPath: installer.directory.appendingPathComponent("reference/slots.md").path))
        // Confirmed replace goes through.
        #expect(try installer.install(files: files, expecting: .different) == .current)
        #expect(installer.status(files: files) == .current)
        // A fresh folder installs; an already current one stays current.
        let other = try tempHome()
        defer { try? FileManager.default.removeItem(at: other) }
        #expect(try ThemeSkillInstaller(home: other).install(files: files, expecting: .notInstalled) == .current)
        #expect(try installer.install(files: files, expecting: .notInstalled) == .current)
    }

    @Test func errorsReadAsSentences() {
        let message = ThemeSkillInstallError.unsafePath("../x").localizedDescription
        #expect(message == "\"../x\" is not a path inside the skill folder.")
    }
}
