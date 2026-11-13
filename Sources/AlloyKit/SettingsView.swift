import AlloyCore
import AlloyLSP
import Foundation
import MetalUI

/// Every app-wide setting, in a full-panel view over the chat column (`settings-view`). Closes on the close button
/// (`settings-close`) or Esc. The toggles save at once; the Claude path saves with Save.
struct SettingsView: Component {
    let workspace: Workspace
    /// Picks the theme; nil hides the theme section.
    var themes: ThemeController?
    let close: @MainActor () -> Void
    @State var path = ""
    @State var loaded = false
    @State var failure: String?
    @State var saved = false
    @State var showDetected = false
    @FocusState var focused: Bool

    var content: some ElementGroup {
        let workspace = workspace
        ScrollView {
        VStack(alignment: .leading, spacing: Pixels(14)) {
            HStack(spacing: 0) {
                Text("Settings").font(size: 16).accessibilityIdentifier("settings-title")
                Spacer()
                Button { close() } label: {
                    Image(systemName: "xmark").font(.system(size: 13)).padding(Pixels(4))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close settings")
                .accessibilityIdentifier("settings-close")
            }
            if let themes {
                ThemeSection(themes: themes, workspace: workspace, close: close)
                Divider()
            }
            VStack(alignment: .leading, spacing: Pixels(8)) {
                Text("Path to claude").font(size: 12).foregroundColor(.mutedInk)
                TextField(workspace.detectedClaudePath ?? "Auto-detect", text: pathBinding)
                    .onSubmit { savePath() }
                    .accessibilityIdentifier("settings-claude-path")
                if let env = Self.envOverride {
                    Text("Overridden by ALLOY_CLAUDE_PATH: \(env)").font(size: 11).foregroundColor(.mutedInk)
                        .accessibilityIdentifier("settings-env-hint")
                }
                if showDetected {
                    Text("Detected: \(workspace.detectedClaudePath ?? "not found")").font(size: 11).foregroundColor(.mutedInk)
                        .accessibilityIdentifier("settings-detected")
                }
                HStack(spacing: Pixels(8)) {
                    Button("Detect") {
                        path = ""; saved = false; failure = nil; showDetected = true
                        Task { await workspace.detectClaude() }
                    }.accessibilityIdentifier("settings-detect")
                    Button("Save") { savePath() }.accessibilityIdentifier("settings-save")
                }
            }
            Divider()
            VStack(alignment: .leading, spacing: Pixels(8)) {
                Text("Editor").font(size: 12).foregroundColor(.mutedInk)
                Toggle(isOn: flag(\.followEdits)) { Text("Follow edits").font(size: 13) }
                    .accessibilityIdentifier("settings-follow-edits")
                Text("Show a session's edits in the right pane as they happen.").font(size: 11).foregroundColor(.mutedInk)
            }
            Divider()
            VStack(alignment: .leading, spacing: Pixels(8)) {
                Text("Shared knowledge").font(size: 12).foregroundColor(.mutedInk)
                Toggle(isOn: flag(\.shareKnowledge)) { Text("Share knowledge between sessions").font(size: 13) }
                    .accessibilityIdentifier("settings-share-knowledge")
                Toggle(isOn: flag(\.shareAcrossProjects)) { Text("Share with other projects").font(size: 13) }
                    .disabled(!workspace.settings.shareKnowledge)
                    .accessibilityIdentifier("settings-share-other-projects")
                Toggle(isOn: flag(\.askBeforeSharedNotes)) { Text("Ask before sessions use Alloy's tools").font(size: 13) }
                    .accessibilityIdentifier("settings-ask-shared-notes")
                Text("Running sessions pick up a change when they are next idle.").font(size: 11).foregroundColor(.mutedInk)
                Button("Back to defaults") { resetKnowledge() }.accessibilityIdentifier("settings-reset")
            }
            if let coordinator = workspace.languageServices as? LSPCoordinator {
                Divider()
                LanguageServersSection(workspace: workspace, builtIn: coordinator.builtIn, locator: coordinator.locator)
            }
            if saved {
                Text("Saved").font(size: 12).foregroundColor(.mutedInk).accessibilityIdentifier("settings-saved")
            }
            if let failure {
                Text(failure).font(size: 12).foregroundColor(.errorInk)
                    .accessibilityIdentifier("settings-error")
            }
        }
        .padding(Pixels(20))
        .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(.panelFill)
        .focusable()
        .focused($focused)
        .onKeyPress(.escape) { close(); return .handled }
        .onAppear {
            focused = true
            if !loaded { loaded = true; path = workspace.settings.claudePath ?? "" }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Settings")
        .accessibilityIdentifier("settings-view")
    }

    /// Editing the path takes back "Saved" and any save error.
    private var pathBinding: Binding<String> {
        Binding(get: { path }, set: { if $0 != path { path = $0; saved = false; failure = nil } })
    }

    private static var envOverride: String? {
        ProcessInfo.processInfo.environment["ALLOY_CLAUDE_PATH"].flatMap { $0.isEmpty ? nil : $0 }
    }

    /// A toggle's binding: reads the saved setting, and writes through `updateSettings` at once.
    private func flag(_ key: WritableKeyPath<AlloySettings, Bool>) -> Binding<Bool> {
        let workspace = workspace
        return Binding(get: { workspace.settings[keyPath: key] },
                       set: { value in
                           var s = workspace.settings
                           s[keyPath: key] = value
                           apply(s)
                       })
    }

    private func resetKnowledge() {
        let defaults = AlloySettings()
        var s = workspace.settings
        s.shareKnowledge = defaults.shareKnowledge
        s.shareAcrossProjects = defaults.shareAcrossProjects
        s.askBeforeSharedNotes = defaults.askBeforeSharedNotes
        apply(s)
    }

    private func apply(_ s: AlloySettings) {
        do { try workspace.updateSettings(s); failure = nil; saved = false } catch { failure = "Could not save: \(error.localizedDescription)" }
    }

    private func savePath() {
        var s = workspace.settings
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        s.claudePath = trimmed.isEmpty ? nil : trimmed
        do { try workspace.updateSettings(s); saved = true; failure = nil } catch {
            saved = false
            failure = "Could not save: \(error.localizedDescription)"
        }
    }
}

/// The language servers part of Settings: one row per known server (name, extensions, whether its command is found on
/// this Mac) with an on/off toggle that saves at once. Lookups run off the main actor and start afresh each time
/// Settings opens, so a server installed meanwhile shows up.
struct LanguageServersSection: Component {
    let workspace: Workspace
    let builtIn: [ServerConfig]
    let locator: ServerLocator
    /// Server id -> found; absent until looked up.
    @State var found: [String: Bool] = [:]
    @State var looked = false
    @State var failure: String?

    var content: some ElementGroup {
        let workspace = workspace
        let servers = ServerRegistry(builtIn: builtIn, overrides: workspace.settings.languageServers).all
        VStack(alignment: .leading, spacing: Pixels(8)) {
            Text("Language servers").font(size: 12).foregroundColor(.mutedInk)
            ForEach(servers, id: \.id) { server in
                HStack(spacing: Pixels(8)) {
                    Toggle(isOn: enabled(server.id, default: server.enabled)) { Text(verbatim: server.name).font(size: 13) }
                        .accessibilityIdentifier("settings-lsp-\(server.id)")
                    Text(verbatim: Self.extensions(server)).font(size: 11).foregroundColor(.mutedInk)
                    Spacer()
                    Text(verbatim: found[server.id].map { $0 ? "Found" : "Not found" } ?? "\u{2026}").font(size: 11)
                        .foregroundColor(found[server.id] == false ? .warningInk : .mutedInk)
                        .accessibilityIdentifier("settings-lsp-status-\(server.id)")
                }
            }
            Text("Alloy never installs or downloads a server; it runs the ones you have.").font(size: 11).foregroundColor(.mutedInk)
            if let failure {
                Text(verbatim: failure).font(size: 11).foregroundColor(.errorInk).accessibilityIdentifier("settings-lsp-error")
            }
        }
        .onAppear { lookUp(servers) }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("settings-lsp-section")
    }

    static func extensions(_ server: ServerConfig) -> String {
        (server.extensions.map { ".\($0)" } + server.fileNames).joined(separator: " ")
    }

    private func enabled(_ id: String, default value: Bool) -> Binding<Bool> {
        let workspace = workspace
        return Binding(get: { workspace.settings.languageServers[id]?.enabled ?? value },
                       set: { on in
                           var s = workspace.settings
                           var o = s.languageServers[id] ?? ServerConfigOverride()
                           o.enabled = on
                           s.languageServers[id] = o
                           do { try workspace.updateSettings(s); failure = nil } catch { failure = "Could not save: \(error.localizedDescription)" }
                       })
    }

    private func lookUp(_ servers: [ServerConfig]) {
        guard !looked else { return }
        looked = true
        let locator = locator
        let commands = servers.map { ($0.id, $0.command) }
        Task {
            let result: [String: Bool] = await Task.detached {
                locator.invalidate()
                return Dictionary(uniqueKeysWithValues: commands.map { ($0.0, locator.resolve($0.1) != nil) })
            }.value
            found = result
        }
    }
}

/// The theme part of Settings: the mode, the theme list(s), load problems and the two buttons. Everything goes through
/// the `ThemeController`, so a pick repaints at once and is saved.
struct ThemeSection: Component {
    let themes: ThemeController
    /// With `close`, enables "Make a theme with Claude…".
    var workspace: Workspace?
    var close: (@MainActor () -> Void)?
    /// A theme choice that could not be saved; shown next to the controls, not in the page's shared error line.
    @State var saveError: String?
    /// The installed theme skill's status; nil until first read (and always nil without an installer).
    @State var skillStatus: ThemeSkillStatus?
    @State var confirmingReplace = false
    @State var skillError: String?
    @State var skillLoaded = false

    var content: some ElementGroup {
        let themes = themes
        let settings = themes.currentSettings
        let library = themes.library
        VStack(alignment: .leading, spacing: Pixels(8)) {
            Text("Theme").font(size: 12).foregroundColor(.mutedInk)
            Picker("Theme mode", selection: modeBinding) {
                Text("One theme").tag(ThemeMode.single)
                Text("Match system").tag(ThemeMode.matchSystem)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .accessibilityIdentifier("settings-theme-mode")
            if settings.themeMode == .single {
                themeList(library.all, selected: settings.theme, listID: "settings-theme-list", rowPrefix: "theme-row-") {
                    pick(theme: $0)
                }
            } else {
                Text("Light appearance").font(size: 11).foregroundColor(.mutedInk)
                themeList(library.all.filter { $0.file.appearance == .light }, selected: settings.lightTheme,
                          listID: "settings-theme-list-light", rowPrefix: "theme-row-light-") { pick(light: $0) }
                Text("Dark appearance").font(size: 11).foregroundColor(.mutedInk)
                themeList(library.all.filter { $0.file.appearance == .dark }, selected: settings.darkTheme,
                          listID: "settings-theme-list-dark", rowPrefix: "theme-row-dark-") { pick(dark: $0) }
            }
            if let notice = themes.notice {
                Text(verbatim: notice).font(size: 11).foregroundColor(.mutedInk).accessibilityIdentifier("settings-theme-notice")
            }
            ForEach(Array(errorRows(library.errors).enumerated()), id: \.offset) { _, row in
                Text(verbatim: row.text).font(size: 11).foregroundColor(.errorInk).accessibilityIdentifier(row.id)
            }
            if let saveError {
                Text(verbatim: saveError).font(size: 11).foregroundColor(.errorInk).accessibilityIdentifier("settings-theme-save-error")
            }
            HStack(spacing: Pixels(8)) {
                Button("Open themes folder") { themes.openThemesFolder(using: themes.folderOpener) }
                    .accessibilityIdentifier("settings-open-themes")
                if let workspace, let close {
                    Button("Make a theme with Claude\u{2026}") {
                        close()
                        Task { await workspace.newThemeSession(description: nil) }
                    }
                    .accessibilityIdentifier("settings-make-theme")
                }
                Button("Back to Dracula") { run { try themes.backToDracula() } }
                    .accessibilityIdentifier("settings-back-to-dracula")
            }
            skillControls
        }
        .onAppear { loadSkillStatus() }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("settings-theme-section")
    }

    // MARK: Theme skill

    private var skillControls: some ElementGroup {
        VStack(alignment: .leading, spacing: Pixels(6)) {
            if let status = skillStatus {
                switch status {
                case .notInstalled:
                    Button("Install theme skill") { install(expecting: .notInstalled) }.accessibilityIdentifier("settings-install-theme-skill")
                case .different:
                    Button("Update theme skill\u{2026}") { confirmingReplace = true }
                        .accessibilityIdentifier("settings-install-theme-skill")
                case .current:
                    Button("Theme skill installed") {}.disabled(true).accessibilityIdentifier("settings-install-theme-skill")
                }
                Text("Lets Claude make Alloy themes in any session, not just /theme.").font(size: 11).foregroundColor(.mutedInk)
                    .accessibilityIdentifier("settings-theme-skill-hint")
                if confirmingReplace && status == .different {
                    VStack(alignment: .leading, spacing: Pixels(6)) {
                        Text("Replace the copy in your skills folder? Changes made to it will be lost.").font(size: 11)
                            .accessibilityIdentifier("settings-theme-skill-confirm")
                        HStack(spacing: Pixels(8)) {
                            Button("Replace") { install(expecting: .different) }.accessibilityIdentifier("settings-theme-skill-replace")
                            Button("Cancel") { confirmingReplace = false }.accessibilityIdentifier("settings-theme-skill-cancel")
                        }
                    }
                }
                if let skillError {
                    Text(verbatim: skillError).font(size: 11).foregroundColor(.errorInk)
                        .accessibilityIdentifier("settings-theme-skill-error")
                }
            }
        }
    }

    private func skillFiles() -> [String: String] { ThemeSkill.files(themesFolder: themes.themesFolderPath) }

    /// Reads the status once, off the main actor.
    private func loadSkillStatus() {
        guard !skillLoaded, let installer = themes.skillInstaller else { return }
        skillLoaded = true
        let files = skillFiles()
        Task {
            let status = await Task.detached { installer.status(files: files) }.value
            skillStatus = status
        }
    }

    /// Writes the skill off the main actor, then shows the new status (or the error).
    private func install(expecting: ThemeSkillStatus) {
        guard let installer = themes.skillInstaller else { return }
        let files = skillFiles()
        confirmingReplace = false
        Task {
            let result: Result<ThemeSkillStatus, Error> = await Task.detached {
                do { return .success(try installer.install(files: files, expecting: expecting)) } catch { return .failure(error) }
            }.value
            switch result {
            case .success(let status):
                skillStatus = status
                skillError = nil
                // Files appeared since the status was read: ask before replacing them.
                confirmingReplace = expecting == .notInstalled && status == .different
            case .failure(let error): skillError = "Could not install the theme skill: \(error.localizedDescription)"
            }
        }
    }

    private func themeList(_ entries: [ThemeEntry], selected: String, listID: String, rowPrefix: String,
                           pick: @escaping @MainActor (String) -> Void) -> some ElementGroup {
        let library = themes.library
        return VStack(alignment: .leading, spacing: Pixels(2)) {
            ForEach(entries, id: \.id) { entry in
                ThemeRow(entry: entry, resolved: library.resolve(entry.id), selected: entry.id == selected,
                         identifier: rowPrefix + entry.id, choose: { pick(entry.id) })
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(listID)
    }

    /// One row per load error. A file's first error is `settings-theme-error-<file>`, later ones `-2`, `-3`...
    private func errorRows(_ errors: [ThemeLoadError]) -> [(text: String, id: String)] {
        var seen: [String: Int] = [:]
        return errors.map { error in
            let n = (seen[error.fileName] ?? 0) + 1
            seen[error.fileName] = n
            return ("\(error.fileName): \(error.message)", "settings-theme-error-\(error.fileName)" + (n > 1 ? "-\(n)" : ""))
        }
    }

    private var modeBinding: Binding<ThemeMode> {
        let themes = themes
        return Binding(get: { themes.currentSettings.themeMode }, set: { mode in run { try themes.choose(mode: mode) } })
    }

    private func pick(theme: String) { run { try themes.request(theme: theme) } }
    private func pick(light: String) { run { try themes.request(light: light) } }
    private func pick(dark: String) { run { try themes.request(dark: dark) } }

    private func run(_ change: () throws -> Void) {
        do { try change(); saveError = nil } catch { saveError = "Could not save the theme: \(error.localizedDescription)" }
    }
}
