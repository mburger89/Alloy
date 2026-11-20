import AlloyCore
import Foundation
import MetalUI

/// The agents part of Settings: the presets (greyed with a copyable install command when their command is missing),
/// the user's custom agents with an add/edit form, the default agent for new sessions, a Detect button, and the names
/// of the secrets kept in the Keychain. Secret values are never shown or typed here (see `secretEntryAvailable`).
/// It exists only while Settings is open, so a closed Settings costs nothing per frame.
struct AgentsSettingsSection: Component {
    /// Flips to true when MetalUI ships a secure text field; until then secrets cannot be entered in Settings, and the
    /// "Add secret" row stays disabled. No other field may stand in for it.
    static let secretEntryAvailable = false
    static let secretEntryCaption = "Secure entry is coming in a later update."

    let workspace: Workspace
    @State var editing: Draft?
    @State var failure: String?
    @State var secrets: [StoredSecret] = []
    @State var loaded = false

    struct Choice: Equatable { var id: String, name: String }
    struct StoredSecret: Equatable { var agent: String, name: String }

    /// The add/edit form's text. `existingID` is set when editing a custom agent.
    struct Draft: Equatable {
        var existingID: String?
        var name = ""
        var command = ""
        var args = ""
        var env = ""
        var secretNames: [String] = []
    }

    var content: some ElementGroup {
        let workspace = workspace
        let defs = workspace.agentDefinitions()
        let defaultID = workspace.settings.defaultAgentID ?? ""
        let choices = [Choice(id: "", name: "Claude")] + workspace.installedAgents.map { Choice(id: $0.id, name: $0.name) }
        VStack(alignment: .leading, spacing: Pixels(8)) {
            Text("Agents").font(size: 12).foregroundColor(.mutedInk).accessibilityIdentifier("settings-agents-heading")
            VStack(alignment: .leading, spacing: Pixels(6)) {
                ForEach(defs, id: \.id) { def in
                    AgentRow(def: def, status: workspace.detectedAgents[def.id], onEdit: { edit(def) }, onRemove: { remove(def) })
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("agents-list")
            Text("Alloy never installs an agent; it shows the command to run.").font(size: 11).foregroundColor(.mutedInk)
            HStack(spacing: Pixels(8)) {
                Button("Detect") { Task { await workspace.detectAgents(force: true) } }.accessibilityIdentifier("agents-detect")
                Button("Add agent\u{2026}") { editing = Draft(); failure = nil }.accessibilityIdentifier("agents-add")
            }
            Text("Default agent for new sessions").font(size: 12).foregroundColor(.mutedInk)
            Picker("Default agent", selection: defaultBinding) {
                ForEach(choices, id: \.id) { Text(verbatim: $0.name).tag($0.id) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .accessibilityIdentifier("agents-default")
            if let draft = editing { form(draft) }
            if workspace.agentSecretsAvailable { secretsList }
            if let failure {
                Text(verbatim: failure).font(size: 11).foregroundColor(.errorInk).accessibilityIdentifier("agents-error")
            }
        }
        .onAppear {
            if !loaded { loaded = true }
            reloadSecrets()
            Task { await workspace.detectAgents() }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("settings-agents-section")
    }

    // MARK: Form

    private func form(_ draft: Draft) -> some ElementGroup {
        VStack(alignment: .leading, spacing: Pixels(6)) {
            Text(draft.existingID == nil ? "New agent" : "Edit agent").font(size: 12).foregroundColor(.mutedInk)
            TextField("Name", text: field(\.name)).accessibilityIdentifier("agents-form-name")
            TextField("Command (name on your PATH, or a full path)", text: field(\.command)).accessibilityIdentifier("agents-form-command")
            TextField("Arguments", text: field(\.args)).accessibilityIdentifier("agents-form-args")
            Text("Environment, one NAME=value per line. Not for secrets.").font(size: 11).foregroundColor(.mutedInk)
            TextField("NAME=value", text: field(\.env), axis: .vertical).accessibilityIdentifier("agents-form-env")
            if let message = Self.envRefusal(draft.env) {
                Text(verbatim: message).font(size: 11).foregroundColor(.errorInk).accessibilityIdentifier("agents-form-env-refusal")
            }
            HStack(spacing: Pixels(8)) {
                Button("Save") { saveDraft() }.accessibilityIdentifier("agents-form-save")
                Button("Cancel") { editing = nil; failure = nil }.accessibilityIdentifier("agents-form-cancel")
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("agents-form")
    }

    private func field(_ key: WritableKeyPath<Draft, String>) -> Binding<String> {
        let state = $editing
        return Binding(get: { state.wrappedValue?[keyPath: key] ?? "" },
                       set: { value in state.wrappedValue?[keyPath: key] = value; failure = nil })
    }

    private var defaultBinding: Binding<String> {
        let workspace = workspace
        return Binding(get: { workspace.settings.defaultAgentID ?? "" }, set: { value in
            do { try workspace.setDefaultAgent(value.isEmpty ? nil : value); failure = nil } catch {
                failure = "Could not save: \(error.localizedDescription)"
            }
        })
    }

    // MARK: Secrets

    @ElementBuilder private var secretsList: some ElementGroup {
        let rows = secrets
        VStack(alignment: .leading, spacing: Pixels(6)) {
            Text("Secrets").font(size: 12).foregroundColor(.mutedInk)
            Text("Kept in your Keychain; only the names are shown here.").font(size: 11).foregroundColor(.mutedInk)
            ForEach(rows, id: \.name) { row in
                HStack(spacing: Pixels(8)) {
                    Text(verbatim: "\(row.agent)  \(row.name)").font(size: 12)
                        .accessibilityIdentifier("agents-secret-\(row.agent)-\(row.name)")
                    Button("Remove") { removeSecret(row) }.accessibilityIdentifier("agents-secret-remove-\(row.agent)-\(row.name)")
                }
            }
            HStack(spacing: Pixels(8)) {
                Button("Add secret") {}.disabled(!Self.secretEntryAvailable).accessibilityIdentifier("agents-secret-add")
                if !Self.secretEntryAvailable {
                    Text(Self.secretEntryCaption).font(size: 11).foregroundColor(.mutedInk).accessibilityIdentifier("agents-secret-add-caption")
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("agents-secrets")
    }

    private func reloadSecrets() {
        secrets = workspace.storedAgentSecrets().map { StoredSecret(agent: $0.agent, name: $0.name) }
    }

    private func removeSecret(_ row: StoredSecret) {
        do { try workspace.removeSecret(agent: row.agent, name: row.name); failure = nil } catch {
            failure = "Could not remove: \(error.localizedDescription)"
        }
        reloadSecrets()
    }

    // MARK: Actions

    private func edit(_ def: AgentDefinition) {
        guard !def.isPreset else { return }
        editing = Draft(existingID: def.id, name: def.name, command: def.command, args: def.args.joined(separator: " "),
                        env: def.env.map { "\($0.name)=\($0.value)" }.joined(separator: "\n"), secretNames: def.secretNames)
        failure = nil
    }

    private func remove(_ def: AgentDefinition) {
        guard !def.isPreset else { return }
        do { try workspace.removeAgent(id: def.id); failure = nil } catch { failure = "Could not remove: \(error.localizedDescription)" }
        if editing?.existingID == def.id { editing = nil }
        reloadSecrets()
    }

    private func saveDraft() {
        guard let draft = editing else { return }
        let name = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let command = draft.command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !command.isEmpty else { failure = "Give the agent a name and a command."; return }
        if let message = Self.envRefusal(draft.env) { failure = message; return }
        guard let env = Self.parseEnv(draft.env) else { failure = "Write each variable as NAME=value."; return }
        let id = draft.existingID ?? uniqueID(for: name)
        let def = AgentDefinition(id: id, name: name, command: command,
                                  args: draft.args.split(whereSeparator: \.isWhitespace).map(String.init),
                                  env: env, secretNames: draft.secretNames)
        do {
            try workspace.saveAgent(def)
            editing = nil; failure = nil
            Task { await workspace.detectAgents() }
        } catch { failure = error.localizedDescription }
    }

    private func uniqueID(for name: String) -> String {
        let slug = String(name.lowercased().map { $0.isLetter || $0.isNumber ? $0 : "-" })
            .split(separator: "-").joined(separator: "-")
        let base = slug.isEmpty ? "agent" : slug
        let taken = Set(workspace.agentDefinitions().map(\.id))
        if !taken.contains(base) { return base }
        var n = 2
        while taken.contains("\(base)-\(n)") { n += 1 }
        return "\(base)-\(n)"
    }

    // MARK: Parsing (pure, for tests)

    /// `NAME=value` lines; nil when a non-empty line has no `=` or an empty name.
    static func parseEnv(_ text: String) -> [EnvVar]? {
        var out: [EnvVar] = []
        for raw in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            guard let eq = line.firstIndex(of: "="), eq != line.startIndex else { return nil }
            out.append(EnvVar(name: String(line[..<eq]).trimmingCharacters(in: .whitespaces), value: String(line[line.index(after: eq)...])))
        }
        return out
    }

    /// The refusal text when any plain variable name looks like a credential, else nil.
    static func envRefusal(_ text: String) -> String? {
        (parseEnv(text) ?? []).contains { EnvVar.looksSecret($0.name) } ? EnvVar.secretRefusal : nil
    }
}

/// One agent: its name, whether its command was found (greyed with the install command and a copy button when not),
/// and Edit / Remove for a custom one.
struct AgentRow: Component {
    let def: AgentDefinition
    let status: AgentStatus?
    let onEdit: () -> Void
    let onRemove: () -> Void
    @Environment(\.clipboard) var clipboard

    var content: some ElementGroup {
        let def = def, clipboard = clipboard
        let missingHint: String?? = { if case .missing(let hint) = status { return .some(hint) } else { return nil } }()
        let installed = { if case .installed = status { return true } else { return false } }()
        VStack(alignment: .leading, spacing: Pixels(2)) {
            HStack(spacing: Pixels(8)) {
                Text(verbatim: def.name).font(size: 13).foregroundColor(installed || status == nil ? .textPrimary : .mutedInk)
                    .accessibilityIdentifier("agents-name-\(def.id)")
                Text(installed ? "Installed" : (status == nil ? "Checking\u{2026}" : "Not installed")).font(size: 11).foregroundColor(.mutedInk)
                    .accessibilityIdentifier("agents-status-\(def.id)")
                if !def.isPreset {
                    Button("Edit") { onEdit() }.accessibilityIdentifier("agents-edit-\(def.id)")
                    Button("Remove") { onRemove() }.accessibilityIdentifier("agents-remove-\(def.id)")
                }
            }
            if let hint = missingHint, let command = hint {
                HStack(spacing: Pixels(6)) {
                    Text(verbatim: command).font(size: 11).foregroundColor(.mutedInk).accessibilityIdentifier("agents-install-\(def.id)")
                    CodeCopyButton(id: "agents-copy-\(def.id)", clipboard: clipboard) { command }
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("agents-row-\(def.id)")
    }
}
