import AlloyCore
import AlloyPlugins
import Foundation
import MetalUI

/// Settings › Plugins: one row per installed plugin (status, source, permissions, enable and remove) and an install
/// button. Reads only `coordinator.status.rows`; each row is a child of its own, so typing in one plugin's setting does
/// not re-run the section.
struct PluginsSection: Component {
    let workspace: Workspace
    let coordinator: PluginCoordinator
    @Environment(\.fileDialogs) var dialogs
    @State var installError: String?

    var content: some ElementGroup {
        let _ = BodyProbe.hit("PluginsSection")
        let rows = coordinator.status.rows
        let coordinator = coordinator, workspace = workspace
        VStack(alignment: .leading, spacing: Pixels(8)) {
            Text("Plugins").font(size: 12).foregroundColor(.mutedInk)
            if rows.isEmpty {
                Text("No plugins installed. Install a folder that holds an alloy-plugin.json.").font(size: 11).foregroundColor(.mutedInk)
                    .accessibilityIdentifier("settings.plugins.empty")
            }
            ForEach(rows, id: \.id) { row in
                PluginRowView(workspace: workspace, coordinator: coordinator, row: row)
            }
            HStack(spacing: Pixels(8)) {
                Button("Install\u{2026}") { install() }.accessibilityIdentifier("settings.plugins.install")
            }
            if let installError {
                Text(verbatim: installError).font(size: 11).foregroundColor(.errorInk)
                    .accessibilityIdentifier("settings.plugins.install-error")
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("settings.plugins")
    }

    private func install() {
        let coordinator = coordinator, dialogs = dialogs
        let state = $installError
        Task { @MainActor in
            let url: URL?
            if let pick = coordinator.pickFolder {
                url = await pick()
            } else {
                url = (try? await dialogs.openFiles(allowedContentTypes: [.folder]))?.first
            }
            guard let url else { return }
            do {
                try await coordinator.install(folder: url)
                state.wrappedValue = nil
            } catch {
                state.wrappedValue = "Could not install: \(Self.describe(error))"
            }
        }
    }

    static func describe(_ error: Error) -> String {
        switch error {
        case let e as PluginInstallError:
            switch e {
            case .badManifest(let m): return m.description
            case .symlinkEscape(let p): return "\(p) points outside the plugin folder"
            case .alreadyInstalled: return "it is already installed from another source"
            case .io(let s): return s
            }
        case let e as PluginError:
            switch e {
            case .noWorkspace: return "no project is open"
            case .unknownPlugin(let id): return "unknown plugin \(id)"
            case .badManifest(let s): return s
            case .needsAPI(let v): return "needs API v\(v)"
            case .sandboxUnavailable: return "this Mac has no sandbox for scripted plugins that use the network or run programs"
            case .scriptedUnsupported: return "scripted plugins arrive in a later Alloy version"
            }
        default:
            return error.localizedDescription
        }
    }
}

/// One installed plugin: status line, enable toggle, permissions, settings disclosure and remove.
struct PluginRowView: Component {
    let workspace: Workspace
    let coordinator: PluginCoordinator
    let row: PluginRowState
    @State var prompting = false
    @State var confirmingRemove = false
    @State var settingsOpen = false
    @State var drafts: [String: String] = [:]
    @State var failure: String?
    @State var logOpen = false
    @State var logText = ""
    @State var storedSecrets: Set<String> = []
    @State var secretDrafts: [String: String] = [:]

    private static let grantText: [PluginPermission: String] = [
        .projectRead: "Read files in this project",
        .projectWrite: "Write files in this project (never .claude or .git)",
        .network: "Use the network",
        .processSpawn: "Run programs",
        .sessionsRead: "See when agent sessions end turns and edit files",
        .mcpTools: "Offer tools to agent sessions",
    ]

    private var inert: Bool {
        switch row.status {
        case .missing, .badManifest: true
        default: false
        }
    }

    var content: some ElementGroup {
        let row = row
        let id = row.id
        let prefix = "settings.plugins.row.\(id)"
        VStack(alignment: .leading, spacing: Pixels(6)) {
            HStack(spacing: Pixels(8)) {
                if inert {
                    Text(verbatim: row.name).font(size: 13)
                } else {
                    Toggle(isOn: enabledBinding) { Text(verbatim: "\(row.name) \(row.version)").font(size: 13) }
                        .disabled(row.status == .scriptedUnavailable)
                        .accessibilityIdentifier("\(prefix).toggle")
                }
                Spacer()
                Text(verbatim: row.status.text).font(size: 11)
                    .foregroundColor(Self.isProblem(row.status) ? .warningInk : .mutedInk)
                    .accessibilityIdentifier("\(prefix).status")
            }
            if let source = row.source {
                Text(verbatim: Self.sourceText(source)).font(size: 11).foregroundColor(.mutedInk)
                    .accessibilityIdentifier("\(prefix).source")
            }
            if !row.permissions.isEmpty {
                Text(verbatim: row.permissions.map(\.rawValue).joined(separator: ", ")).font(size: 11).foregroundColor(.mutedInk)
                    .accessibilityIdentifier("\(prefix).permissions")
            }
            ForEach(Array(row.notes.enumerated()), id: \.offset) { index, note in
                Text(verbatim: note).font(size: 11).foregroundColor(.warningInk)
                    .accessibilityIdentifier(index == 0 ? "\(prefix).notes" : "\(prefix).notes.\(index)")
            }
            if prompting {
                enablePrompt
            }
            if row.enabled && !row.permissions.isEmpty {
                VStack(alignment: .leading, spacing: Pixels(4)) {
                    ForEach(row.permissions, id: \.self) { p in
                        Toggle(isOn: grantBinding(p)) { Text(verbatim: Self.grantText[p] ?? p.rawValue).font(size: 11) }
                            .accessibilityIdentifier("settings.plugins.grant.\(id).\(p.rawValue)")
                    }
                }
            }
            if !row.settings.isEmpty && !inert {
                VStack(alignment: .leading, spacing: 0) {
                    DisclosureGroup(isExpanded: $settingsOpen) {
                        VStack(alignment: .leading, spacing: Pixels(6)) {
                            ForEach(row.settings, id: \.key) { spec in settingControl(spec) }
                        }
                    } label: {
                        Text("Settings").font(size: 11).foregroundColor(.mutedInk)
                    }
                }
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("settings.plugins.settings.\(id)")
            }
            if row.isScripted && !inert {
                Button("Log") { toggleLog() }.accessibilityIdentifier("\(prefix).log")
                if logOpen {
                    Text(verbatim: logText.isEmpty ? "No output." : logText).font(size: 11).foregroundColor(.mutedInk)
                        .accessibilityIdentifier("\(prefix).log-text")
                }
            }
            if confirmingRemove {
                VStack(alignment: .leading, spacing: Pixels(4)) {
                    Text(verbatim: "Remove \(row.name)? Its folder and settings are deleted.").font(size: 11)
                        .accessibilityIdentifier("\(prefix).remove-confirm-text")
                    HStack(spacing: Pixels(8)) {
                        Button("Remove") { remove() }.accessibilityIdentifier("\(prefix).remove-confirm")
                        Button("Cancel") { confirmingRemove = false }.accessibilityIdentifier("\(prefix).remove-cancel")
                    }
                }
            } else {
                Button("Remove") { confirmingRemove = true }.accessibilityIdentifier("\(prefix).remove")
            }
            if let failure {
                Text(verbatim: failure).font(size: 11).foregroundColor(.errorInk).accessibilityIdentifier("settings.plugins.error")
            }
        }
        .onAppear { loadStoredSecrets() }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(prefix)
    }

    // MARK: Secrets

    private func loadStoredSecrets() {
        guard row.settings.contains(where: { if case .secret = $0.type { true } else { false } }) else { return }
        let coordinator = coordinator, id = row.id, stored = $storedSecrets
        Task { @MainActor in stored.wrappedValue = await coordinator.storedSecretKeys(for: id) }
    }

    private func saveSecret(_ key: String) {
        let value = secretDrafts[key] ?? ""
        guard !value.isEmpty else { return }
        // The typed value leaves state before the Keychain is touched.
        secretDrafts[key] = nil
        do {
            try coordinator.setSecret(value, key: key, for: row.id)
            storedSecrets.insert(key)
            failure = nil
        } catch {
            failure = "Could not save the secret: \(PluginsSection.describe(error))"
        }
    }

    private func removeSecret(_ key: String) {
        do {
            try coordinator.clearSecret(key: key, for: row.id)
            storedSecrets.remove(key)
            failure = nil
        } catch {
            failure = "Could not remove the secret: \(PluginsSection.describe(error))"
        }
    }

    private func secretControl(_ spec: PluginSettingSpec, id: String) -> some ElementGroup {
        let key = spec.key, pluginID = row.id
        let draftBinding = Binding<String>(get: { secretDrafts[key] ?? "" }, set: { secretDrafts[key] = $0 })
        return VStack(alignment: .leading, spacing: Pixels(4)) {
            Text(verbatim: spec.title).font(size: 11).foregroundColor(.mutedInk)
            if !coordinator.secretsAvailable {
                Text("Secrets need the Keychain, which is unavailable here.").font(size: 11).foregroundColor(.warningInk)
                    .accessibilityIdentifier("settings.plugins.secret-unavailable.\(pluginID).\(key)")
            } else {
                if storedSecrets.contains(key) {
                    HStack(spacing: Pixels(8)) {
                        Text("Stored in your Keychain").font(size: 11).foregroundColor(.mutedInk)
                            .accessibilityIdentifier("settings.plugins.secret-stored.\(pluginID).\(key)")
                        Button("Remove") { removeSecret(key) }
                            .accessibilityIdentifier("settings.plugins.secret-remove.\(pluginID).\(key)")
                    }
                }
                SecureField(spec.title, text: draftBinding)
                    .onSubmit { saveSecret(key) }
                    .accessibilityIdentifier(id)
                Button("Save") { saveSecret(key) }
                    .disabled((secretDrafts[key] ?? "").isEmpty)
                    .accessibilityIdentifier("settings.plugins.secret-save.\(pluginID).\(key)")
            }
        }
    }

    // MARK: Enable prompt

    private var enablePrompt: some ElementGroup {
        let row = row, id = row.id
        return VStack(alignment: .leading, spacing: Pixels(4)) {
            Text(verbatim: "Enable \(row.name) \(row.version) from \(row.source.map(Self.sourceText) ?? "unknown")?").font(size: 12)
            ForEach(row.permissions, id: \.self) { p in
                Text(verbatim: Self.grantText[p] ?? p.rawValue).font(size: 11)
                    .accessibilityIdentifier("settings.plugins.grant.\(id).\(p.rawValue)")
            }
            if row.isScripted {
                Text("Runs with your account's file access.").font(size: 11).foregroundColor(.mutedInk)
                    .accessibilityIdentifier("settings.plugins.enable-runs.\(id)")
            } else {
                ForEach(Array(row.commandsToRun.enumerated()), id: \.offset) { index, command in
                    Text(verbatim: "Runs: \(command)").font(size: 11).foregroundColor(.mutedInk)
                        .accessibilityIdentifier("settings.plugins.enable-runs.\(id).\(index)")
                }
            }
            HStack(spacing: Pixels(8)) {
                Button("Enable and grant") { confirmEnable() }.accessibilityIdentifier("settings.plugins.enable-confirm.\(id)")
                Button("Cancel") { prompting = false }.accessibilityIdentifier("settings.plugins.enable-cancel.\(id)")
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("settings.plugins.enable-prompt.\(id)")
    }

    // MARK: Actions

    private var enabledBinding: Binding<Bool> {
        let coordinator = coordinator, id = row.id
        let state = $failure, prompt = $prompting
        return Binding(get: { prompting || row.enabled }, set: { on in
            if on {
                state.wrappedValue = nil
                prompt.wrappedValue = true
            } else {
                prompt.wrappedValue = false
                do { try coordinator.disable(id); state.wrappedValue = nil } catch {
                    state.wrappedValue = "Could not save: \(PluginsSection.describe(error))"
                }
            }
        })
    }

    private func confirmEnable() {
        do {
            try coordinator.enable(row.id)
            prompting = false
            failure = nil
        } catch {
            prompting = false
            failure = "Could not save: \(PluginsSection.describe(error))"
        }
    }

    private func grantBinding(_ p: PluginPermission) -> Binding<Bool> {
        let coordinator = coordinator, id = row.id, workspace = workspace
        let state = $failure
        return Binding(get: { workspace.settings.plugins[id]?.grants.contains(p) ?? false }, set: { on in
            do { try coordinator.setGrant(p, on, for: id); state.wrappedValue = nil } catch {
                state.wrappedValue = "Could not save: \(PluginsSection.describe(error))"
            }
        })
    }

    /// Expands or collapses the log under the row; opening reads the redacted stderr tail from the host.
    private func toggleLog() {
        if logOpen { logOpen = false; return }
        let coordinator = coordinator, id = row.id
        let open = $logOpen, text = $logText
        Task { @MainActor in
            text.wrappedValue = await coordinator.logText(for: id)
            open.wrappedValue = true
        }
    }

    private func remove() {
        let coordinator = coordinator, id = row.id
        let state = $failure, confirm = $confirmingRemove
        Task { @MainActor in
            do { try await coordinator.remove(id) } catch {
                confirm.wrappedValue = false
                state.wrappedValue = "Could not save: \(PluginsSection.describe(error))"
            }
        }
    }

    // MARK: Declared settings

    private func stored(_ spec: PluginSettingSpec) -> JSONValue? {
        workspace.settings.plugins[row.id]?.values[spec.key] ?? spec.defaultValue
    }

    private func save(_ value: JSONValue?, _ key: String) {
        do { try coordinator.setValue(value, key: key, for: row.id); failure = nil } catch {
            failure = "Could not save: \(PluginsSection.describe(error))"
        }
    }

    private func settingControl(_ spec: PluginSettingSpec) -> some ElementGroup {
        let id = "settings.plugins.value.\(row.id).\(spec.key)"
        let key = spec.key
        return VStack(alignment: .leading, spacing: Pixels(2)) {
            switch spec.type {
            case .bool:
                Toggle(isOn: Binding(get: { if case .bool(let b)? = stored(spec) { b } else { false } },
                                     set: { save(.bool($0), key) })) { Text(verbatim: spec.title).font(size: 12) }
                    .accessibilityIdentifier(id)
            case .string:
                Text(verbatim: spec.title).font(size: 11).foregroundColor(.mutedInk)
                TextField(spec.title, text: draft(spec))
                    .onSubmit { save(.string(drafts[key] ?? Self.text(stored(spec))), key) }
                    .accessibilityIdentifier(id)
            case .number:
                Text(verbatim: spec.title).font(size: 11).foregroundColor(.mutedInk)
                TextField(spec.title, text: draft(spec))
                    .onSubmit {
                        let text = (drafts[key] ?? Self.text(stored(spec))).trimmingCharacters(in: .whitespaces)
                        if let d = Double(text), d.isFinite { save(.number(d), key) }
                    }
                    .accessibilityIdentifier(id)
            case .secret:
                secretControl(spec, id: id)
            case .enumeration(let options):
                Text(verbatim: spec.title).font(size: 11).foregroundColor(.mutedInk)
                Picker(spec.title, selection: Binding(get: { Self.text(stored(spec)) }, set: { save(.string($0), key) })) {
                    ForEach(options, id: \.self) { Text(verbatim: $0).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .accessibilityIdentifier(id)
            }
        }
    }

    private func draft(_ spec: PluginSettingSpec) -> Binding<String> {
        let state = $drafts, key = spec.key
        let current = Self.text(stored(spec))
        return Binding(get: { state.wrappedValue[key] ?? current }, set: { state.wrappedValue[key] = $0 })
    }

    // MARK: Text

    static func text(_ value: JSONValue?) -> String {
        switch value {
        case .string(let s)?: s
        case .number(let d)?: d == d.rounded() && abs(d) < 1e15 ? String(Int(d)) : String(d)
        case .bool(let b)?: String(b)
        default: ""
        }
    }

    static func sourceText(_ source: PluginSource) -> String {
        switch source {
        case .folder(let path): "Folder: \(path)"
        case .git(let url, let tag, _): "Git: \(url) at \(tag)"
        }
    }

    static func isProblem(_ s: PluginRowStatus) -> Bool {
        switch s {
        case .disabled, .notStarted, .running, .stopped, .enabled, .notEnabled, .scriptedUnavailable: false
        default: true
        }
    }
}
