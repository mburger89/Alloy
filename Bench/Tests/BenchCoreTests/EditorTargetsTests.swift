import Testing
import Foundation
@testable import BenchCore
@testable import BenchDrivers

/// Nothing here launches an editor.
@Suite struct EditorTargetsTests {
    static let file = "/a b/c.swift"

    @Test func identities() {
        let rows: [(TargetApp, String, String, String, String, String)] = [
            (.vscode, "vscode", "VS Code", "com.microsoft.VSCode", "/Applications/Visual Studio Code.app", "Code"),
            (.cursor, "cursor", "Cursor", "com.todesktop.230313mzl4w4u92", "/Applications/Cursor.app", "Cursor"),
            (.sublime, "sublime", "Sublime Text", "com.sublimetext.4", "/Applications/Sublime Text.app", "sublime_text"),
            (.idea, "idea", "IntelliJ IDEA", "com.jetbrains.intellij", "/Applications/IntelliJ IDEA.app", "idea"),
        ]
        for (t, id, name, bundle, path, exe) in rows {
            #expect(t.id == id)
            #expect(t.displayName == name)
            #expect(t.bundleID == bundle)
            #expect(t.bundlePath == path)
            #expect(t.executablePath == path + "/Contents/MacOS/" + exe)
        }
        #expect(TargetApp.editors.map(\.id) == ["vscode", "cursor", "sublime", "idea"])
        #expect(Set(TargetApp.editors.compactMap(\.bundleID)).count == 4)
        #expect(Set(TargetApp.editors.map(\.executablePath)).count == 4)
    }

    @Test func electronArguments() {
        for t in [TargetApp.vscode, .cursor] {
            #expect(Launcher.arguments(for: t, file: Self.file, userDataDir: "/p") == [
                "--user-data-dir", "/p", "--extensions-dir", "/p/extensions", "--disable-extensions",
                "--skip-welcome", "--skip-release-notes", "--disable-workspace-trust", Self.file])
            #expect(Launcher.arguments(for: t, file: nil, userDataDir: "/p").last == "--disable-workspace-trust")
            #expect(Launcher.environment(for: t, userDataDir: "/p", base: [:]) == nil)
            #expect(t.typingClickPoint == nil)
        }
    }

    @Test func electronSeededSettings() throws {
        for t in [TargetApp.vscode, .cursor] {
            let text = try #require(t.seededFiles["User/settings.json"])
            let json = try #require(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: String])
            #expect(json == ["telemetry.telemetryLevel": "off", "update.mode": "none",
                             "workbench.startupEditor": "none", "editor.cursorBlinking": "solid"])
        }
    }

    @Test func sublimeArguments() {
        let t = TargetApp.sublime
        #expect(Launcher.arguments(for: t, file: Self.file, userDataDir: nil) == ["--safe-mode", Self.file])
        #expect(Launcher.arguments(for: t, file: nil, userDataDir: nil) == ["--safe-mode"])
        #expect(t.userDataDirFlag == nil && t.dataDirEnvironmentKey == nil && t.seededFiles.isEmpty)
        #expect(Launcher.environment(for: t, userDataDir: nil, base: [:]) == nil)
    }

    @Test func ideaArgumentsEnvironmentAndSeed() throws {
        let t = TargetApp.idea
        #expect(Launcher.arguments(for: t, file: Self.file, userDataDir: "/p") == [Self.file])
        #expect(Launcher.arguments(for: t, file: nil, userDataDir: "/p") == [])
        let env = Launcher.environment(for: t, userDataDir: "/p", base: ["X": "1"])
        #expect(env == ["X": "1", "IDEA_PROPERTIES": "/p/idea.properties"])
        let dir = NSTemporaryDirectory() + "idea-seed-" + UUID().uuidString
        defer { try? FileManager.default.removeItem(atPath: dir) }
        try Launcher.seed(t.seededFiles, into: dir)
        let props = try String(contentsOfFile: dir + "/idea.properties", encoding: .utf8)
        for key in ["idea.config.path", "idea.system.path", "idea.plugins.path", "idea.log.path"] {
            #expect(props.contains("\(key)=\(dir)/"))
        }
        #expect(!props.contains(TargetApp.profileDirPlaceholder))
        let xml = try String(contentsOfFile: dir + "/config/options/ide.general.xml", encoding: .utf8)
        #expect(xml.contains("showTipsOnStartup"))
    }

    @Test func refusalMatchingUsesBundleIDAndExecutablePath() {
        for t in TargetApp.editors {
            #expect(!(t.bundleID ?? "").isEmpty)
            #expect(t.executablePath.hasPrefix("/Applications/"))
            #expect(t.executablePath.hasPrefix(t.bundlePath ?? "?"))
            // Matching is by exact executable path; asking must not trap whether or not the editor runs.
            _ = Launcher.pidsRunning(path: t.executablePath)
        }
    }

    @Test func textsContainNothingPrivate() throws {
        let scrubber = Scrubber(home: NSHomeDirectory(), userName: NSUserName())
        for t in TargetApp.editors {
            #expect(!t.caveats.isEmpty)
            for text in t.caveats + t.unsupported.values + t.seededFiles.values + t.seededFiles.keys {
                #expect(!text.isEmpty)
                #expect(scrubber.leaks(in: text).isEmpty)
            }
        }
    }

    @Test(arguments: [("Visual Studio Code", "Code", "com.microsoft.VSCode", "vscode"),
                      ("Cursor", "Cursor", "com.todesktop.230313mzl4w4u92", "cursor"),
                      ("Sublime Text", "sublime_text", "com.sublimetext.4", "sublime"),
                      ("IntelliJ IDEA", "idea", "com.jetbrains.intellij", "idea")])
    func installedAppMatches(app: String, exe: String, bundle: String, id: String) throws {
        let plist = "/Applications/\(app).app/Contents/Info.plist"
        guard let info = NSDictionary(contentsOfFile: plist) else { return }  // not installed: nothing to check
        let t = try #require(TargetApp.editors.first { $0.id == id })
        #expect(info["CFBundleExecutable"] as? String == exe)
        #expect(info["CFBundleIdentifier"] as? String == bundle)
        #expect(t.executablePath.hasSuffix("/" + exe))
        #expect(t.bundleID == bundle)
        #expect(t.version() != "unknown")
    }
}
