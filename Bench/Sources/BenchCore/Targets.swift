import CoreGraphics
import Foundation

public enum Metric: String, Codable, CaseIterable, Sendable {
    case startup, typingLatency, scrollFrames, memory, memoryIdle, largeFileOpen, idleCPU
}

/// An app under measurement. Not Codable (holds a closure); results store id + version only.
public struct TargetApp: Sendable {
    public var id: String
    public var displayName: String
    public var bundlePath: String?
    public var executablePath: String
    public var launchArguments: @Sendable (_ file: String?) -> [String]
    /// metric -> reason it cannot be measured; recorded as "n/a: <reason>".
    public var unsupported: [Metric: String]
    /// Alloy repo root, used for `git describe` (nil for bundled apps).
    public var repoPath: String?
    /// Bundle identifier, used to detect an already-running instance through NSRunningApplication.
    public var bundleID: String?
    /// Flag that takes a per-run temporary user-data directory (`--user-data-dir` for Zed); nil when the app has none.
    public var userDataDirFlag: String?
    /// Environment variable that takes a per-run temporary user-data directory (`ALLOY_DATA_DIR` for Alloy); nil when
    /// the app has none. Like `userDataDirFlag`, the launcher creates the directory and removes it afterwards.
    public var dataDirEnvironmentKey: String?
    /// Where scroll events are posted, given the main window's frame (global top-left coordinates). Default: the
    /// window centre. Alloy overrides it with the centre of its file panel.
    public var scrollPoint: @Sendable (_ windowFrame: CGRect) -> CGPoint
    /// Where a single click is posted before the typing script, to focus the editor; nil when the app opens with the
    /// editor already focused. Alloy uses its scroll point (inside the CodeView, below the tab strip).
    public var typingClickPoint: (@Sendable (_ windowFrame: CGRect) -> CGPoint)?
    /// Isolation or measurement caveats recorded in the notes of every measured result for this app.
    public var caveats: [String]
    /// Files written into the per-run user-data directory before launch (relative path -> contents). Zed gets
    /// `config/settings.json` with `session.trust_all_worktrees`, which skips Zed 1.28's first-open trust prompt
    /// (it would otherwise cover the editor and swallow keystrokes); it is the state of a user who has trusted the project.
    /// `enable_language_server: false` keeps Zed from starting (or downloading) rust-analyzer for the Rust corpus; Alloy has none.
    public var seededFiles: [String: String]
    /// Placeholder in seeded file contents that the launcher replaces with the per-run profile directory.
    public static let profileDirPlaceholder = "@PROFILE_DIR@"
    /// Extra arguments that depend on the per-run profile directory, appended after `userDataDirFlag <dir>` and
    /// before `launchArguments` (VS Code's `--extensions-dir <dir>/extensions`).
    public var profileArguments: @Sendable (_ profileDir: String) -> [String]
    /// Value for `dataDirEnvironmentKey` given the profile directory; default is the bare directory
    /// (IntelliJ points its key at a properties file inside it).
    public var dataDirEnvironmentValue: @Sendable (_ profileDir: String) -> String

    public init(id: String, displayName: String, bundlePath: String?, executablePath: String,
                launchArguments: @escaping @Sendable (String?) -> [String],
                unsupported: [Metric: String] = [:], repoPath: String? = nil,
                bundleID: String? = nil, userDataDirFlag: String? = nil, dataDirEnvironmentKey: String? = nil,
                caveats: [String] = [], seededFiles: [String: String] = [:],
                scrollPoint: @escaping @Sendable (CGRect) -> CGPoint = { CGPoint(x: $0.midX, y: $0.midY) },
                typingClickPoint: (@Sendable (CGRect) -> CGPoint)? = nil,
                profileArguments: @escaping @Sendable (String) -> [String] = { _ in [] },
                dataDirEnvironmentValue: @escaping @Sendable (String) -> String = { $0 }) {
        self.id = id; self.displayName = displayName; self.bundlePath = bundlePath
        self.executablePath = executablePath; self.launchArguments = launchArguments
        self.unsupported = unsupported; self.repoPath = repoPath
        self.bundleID = bundleID; self.userDataDirFlag = userDataDirFlag; self.caveats = caveats; self.seededFiles = seededFiles
        self.dataDirEnvironmentKey = dataDirEnvironmentKey
        self.scrollPoint = scrollPoint; self.typingClickPoint = typingClickPoint
        self.profileArguments = profileArguments; self.dataDirEnvironmentValue = dataDirEnvironmentValue
    }

    /// The real app binary (not the `zed` CLI shim, which forks and exits), so the launched PID is the app.
    public static let zed = TargetApp(
        id: "zed", displayName: "Zed", bundlePath: "/Applications/Zed.app",
        executablePath: "/Applications/Zed.app/Contents/MacOS/zed",
        // The app binary takes `paths_or_urls`, `--diff`, `--user-data-dir`, ...; `-n` belongs to the CLI shim only.
        launchArguments: { file in file.map { [$0] } ?? [] },
        bundleID: "dev.zed.Zed", userDataDirFlag: "--user-data-dir",
        caveats: ["Zed: per-run profile pre-trusts the project (session.trust_all_worktrees) and turns language servers off (enable_language_server: false); Alloy runs none"],
        seededFiles: ["config/settings.json": "{\"session\":{\"trust_all_worktrees\":true},\"enable_language_server\":false}\n"])

    public static let delta = TargetApp(
        id: "delta", displayName: "Delta", bundlePath: "/Applications/Delta.app",
        executablePath: "/Applications/Delta.app/Contents/MacOS/delta-app",
        // `delta-app --help`: `[DIR_OR_URL]` is a project directory or delta:// URL, not a file.
        // So a file maps to its parent directory (opens a project window); nil launches with no args.
        launchArguments: { file in file.map { [($0 as NSString).deletingLastPathComponent] } ?? [] },
        unsupported: [
            .typingLatency: "Delta is agent-first with no documented way to open a file in an editor surface; typing target unverified",
            .largeFileOpen: "Delta has no documented open-file-in-editor command (`delta open` takes a path or delta:// link only)",
            .scrollFrames: "Delta opens projects, not files; needs a live probe to learn what it displays",
            .memory: "Delta opens projects, not files; needs a live probe to learn what it displays",
        ],
        bundleID: "com.zed-industries.delta",
        caveats: ["Delta has no isolation flag: it ran against the user's real Delta profile and state"])

    // MARK: Editors measured against Alloy (never launched by tests)

    /// All four optional editors in catalogue order.
    public static let editors: [TargetApp] = [vscode, cursor, sublime, idea]

    public static let vscode = electronEditor(
        id: "vscode", displayName: "VS Code", app: "Visual Studio Code", executable: "Code",
        bundleID: "com.microsoft.VSCode", caveats: [
            "VS Code: per-run profile (--user-data-dir and --extensions-dir) with extensions disabled, telemetry and update checks off, no welcome tab or workspace trust prompt; opens already focused (no typing click yet)",
        ])

    public static let cursor = electronEditor(
        id: "cursor", displayName: "Cursor", app: "Cursor", executable: "Cursor",
        bundleID: "com.todesktop.230313mzl4w4u92", caveats: [
            "Cursor: same flags and profile as VS Code (same Electron base); a fresh profile may show login or onboarding that no flag skips, which the live probe must confirm and record per metric",
        ])

    /// VS Code and Cursor share an Electron base: two flags isolate the profile, three skip first-run screens.
    private static func electronEditor(id: String, displayName: String, app: String, executable: String,
                                       bundleID: String, caveats: [String]) -> TargetApp {
        TargetApp(
            id: id, displayName: displayName, bundlePath: "/Applications/\(app).app",
            executablePath: "/Applications/\(app).app/Contents/MacOS/\(executable)",
            launchArguments: { file in
                ["--disable-extensions", "--skip-welcome", "--skip-release-notes", "--disable-workspace-trust"]
                    + (file.map { [$0] } ?? [])
            },
            bundleID: bundleID, userDataDirFlag: "--user-data-dir",
            caveats: caveats,
            seededFiles: ["User/settings.json": electronSettings],
            profileArguments: { ["--extensions-dir", $0 + "/extensions"] })
    }

    private static let electronSettings = """
        {"telemetry.telemetryLevel":"off","update.mode":"none","workbench.startupEditor":"none","editor.cursorBlinking":"solid"}

        """

    public static let sublime = TargetApp(
        id: "sublime", displayName: "Sublime Text", bundlePath: "/Applications/Sublime Text.app",
        executablePath: "/Applications/Sublime Text.app/Contents/MacOS/sublime_text",
        launchArguments: { file in ["--safe-mode"] + (file.map { [$0] } ?? []) },
        bundleID: "com.sublimetext.4",
        caveats: [
            "Sublime Text: launched with --safe-mode (clean sandboxed environment, no packages); safe mode ignores user settings, so the caret may blink",
            "Sublime Text: safe mode uses its own data folder that the harness does not clean; whether it persists state outside the run is an open question for the live probe",
        ])

    public static let idea = TargetApp(
        id: "idea", displayName: "IntelliJ IDEA", bundlePath: "/Applications/IntelliJ IDEA.app",
        executablePath: "/Applications/IntelliJ IDEA.app/Contents/MacOS/idea",
        launchArguments: { file in file.map { [$0] } ?? [] },
        bundleID: "com.jetbrains.intellij",
        dataDirEnvironmentKey: "IDEA_PROPERTIES",
        caveats: [
            "IntelliJ IDEA: per-run config, system, plugins and log directories through IDEA_PROPERTIES; post-open indexing inflates startup and memory",
            "IntelliJ IDEA: licence and data-sharing consent are stored outside the profile, so a first-run dialog may remain; open question for the live probe, which records the affected metrics as n/a if so",
            "IntelliJ IDEA: whether the launcher runs the JVM in the launched process is an open question for the live probe",
        ],
        seededFiles: [
            "idea.properties": ideaProperties,
            "config/options/ide.general.xml": ideaGeneralXML,
        ],
        dataDirEnvironmentValue: { $0 + "/idea.properties" })

    private static let ideaProperties = """
        idea.config.path=@PROFILE_DIR@/config
        idea.system.path=@PROFILE_DIR@/system
        idea.plugins.path=@PROFILE_DIR@/plugins
        idea.log.path=@PROFILE_DIR@/log
        idea.initially.ask.config=false
        idea.trust.all.projects=true
        jb.consents.confirmation.enabled=false
        ide.show.tips.on.startup.default.value=false

        """

    private static let ideaGeneralXML = """
        <application>
          <component name="GeneralSettings">
            <option name="showTipsOnStartup" value="false" />
            <option name="confirmExit" value="false" />
          </component>
        </application>

        """

    /// - Parameter buildDir: the Alloy repo root (not the `.build` directory); the binary is `<buildDir>/.build/release/Alloy`.
    /// Launched as `Alloy <project-dir> [<file>]`.
    public static func alloy(buildDir: String) -> TargetApp {
        TargetApp(
            id: "alloy", displayName: "Alloy", bundlePath: nil,
            executablePath: buildDir + "/.build/release/Alloy",
            launchArguments: { file in [(file.map { ($0 as NSString).deletingLastPathComponent }) ?? "."] + (file.map { [$0] } ?? []) },
            repoPath: buildDir,
            dataDirEnvironmentKey: "ALLOY_DATA_DIR",
            scrollPoint: alloyFilePanelPoint,
            typingClickPoint: alloyFilePanelPoint)
    }

    /// The file panel's centre: the vertical middle is far below the tab strip and path header at the panel's top.
    @Sendable static func alloyFilePanelPoint(_ windowFrame: CGRect) -> CGPoint {
        CGPoint(x: windowFrame.maxX - alloyFilePanelCentreFromRight, y: windowFrame.midY)
    }

    /// Distance (pt) from the window's right edge to the centre of Alloy's file panel. Mirrors
    /// `alloyFilePanelIdealWidth` (360 pt) / 2 in `Sources/AlloyKit/RootView.swift`: the panel is the trailing
    /// column of the HSplitView (sidebar | chat | file panel) and keeps its ideal width when the window resizes,
    /// whereas the window centre (x = 600 of 1200) lands in the chat column, which never scrolls the file.
    /// Keep both constants in sync (the Bench package cannot import AlloyKit).
    public static let alloyFilePanelCentreFromRight: Double = 180

    /// CFBundleShortVersionString; for Alloy `git -C <repo> describe --always --dirty`.
    public func version() -> String {
        if let repo = repoPath {
            return run("/usr/bin/git", ["-C", repo, "describe", "--always", "--dirty"]) ?? "unknown"
        }
        if let b = bundlePath,
           let info = NSDictionary(contentsOfFile: b + "/Contents/Info.plist"),
           let v = info["CFBundleShortVersionString"] as? String { return v }
        return "unknown"
    }

    private func run(_ exe: String, _ args: [String]) -> String? {
        let p = Process(); p.executableURL = URL(fileURLWithPath: exe); p.arguments = args
        let pipe = Pipe(); p.standardOutput = pipe; p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit()
        guard p.terminationStatus == 0 else { return nil }
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
