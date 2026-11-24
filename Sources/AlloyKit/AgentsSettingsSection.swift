import AlloyCore
import Foundation
import MetalUI

/// The agents part of Settings: the presets (greyed with a copyable install command when their command is missing),
/// the user's custom agents with an add/edit form, the default agent for new sessions, a Detect button, and the names
/// of the secrets kept in the Keychain. A secret value is typed only into a `SecureField`, goes straight to the Keychain
/// on Save and is cleared at once; it is never shown, logged or kept.
/// It exists only while Settings is open, so a closed Settings costs nothing per frame.
struct AgentsSettingsSection: Component {
    static let secretEntryCaption = "Kept in your Keychain. Saving a name that exists replaces its value."
    static let invalidNameMessage = "Use capital letters, digits and underscores, not starting with a digit."

    let workspace: Workspace
    @State var editing: Draft?
    @State var failure: String?
    @State var secrets: [StoredSecret] = []
    @State var loaded = false
    /// The Add secret form (agent and name). The value lives in `secretValue` and is reset on Save and Cancel.
    @State var secretDraft: SecretDraft?
    @State var secretValue = ""
    @State var secretNotice: String?

    struct Choice: Equatable { var id: String, name: String }
    struct StoredSecret: Equatable { var agent: String, name: String }
    struct SecretDraft: Equatable { var agent: String, name = "" }

    /// `[A-Z_][A-Z0-9_]*`.
    static func isValidSecretName(_ name: String) -> Bool {
        guard let first = name.unicodeScalars.first, !("0"..."9" as ClosedRange<Unicode.Scalar>).contains(first) else { return false }
        return name.unicodeScalars.allSatisfy {
            ("A"..."Z" as ClosedRange<Unicode.Scalar>).contains($0) || ("0"..."9" as ClosedRange<Unicode.Scalar>).contains($0) || $0 == "_"
        }
    }

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
            if let draft = secretDraft {
                secretForm(draft)
            } else {
                HStack(spacing: Pixels(8)) {
                    Button("Add secret") { openSecretForm() }.accessibilityIdentifier("agents-secret-add")
                    Text(Self.secretEntryCaption).font(size: 11).foregroundColor(.mutedInk)
                        .accessibilityIdentifier("agents-secret-add-caption")
                }
            }
            if let secretNotice {
                Text(verbatim: secretNotice).font(size: 11).foregroundColor(.mutedInk).accessibilityIdentifier("agents-secret-notice")
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("agents-secrets")
    }

    private var secretAgents: [AgentDefinition] { workspace.agentDefinitions() }

    private func secretForm(_ draft: SecretDraft) -> some ElementGroup {
        let agents = secretAgents
        let nameBinding = Binding<String>(get: { secretDraft?.name ?? "" }, set: { value in
            secretDraft?.name = value.uppercased(); secretNotice = nil; failure = nil
        })
        let agentBinding = Binding<String>(get: { secretDraft?.agent ?? "" }, set: { secretDraft?.agent = $0 })
        let nameOK = Self.isValidSecretName(draft.name)
        let canSave = nameOK && !secretValue.isEmpty && agents.contains { $0.id == draft.agent }
        return VStack(alignment: .leading, spacing: Pixels(6)) {
            Text("New secret").font(size: 12).foregroundColor(.mutedInk)
            if agents.count > 1 {
                Picker("Agent", selection: agentBinding) {
                    ForEach(agents, id: \.id) { Text(verbatim: $0.name).tag($0.id) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .accessibilityIdentifier("agents-secret-agent")
            }
            TextField("Variable name, for example API_KEY", text: nameBinding).accessibilityIdentifier("agents-secret-name")
            if !draft.name.isEmpty && !nameOK {
                Text(Self.invalidNameMessage).font(size: 11).foregroundColor(.errorInk).accessibilityIdentifier("agents-secret-name-refusal")
            }
            SecureField("Value", text: $secretValue)
                .onSubmit { saveSecret() }
                .accessibilityIdentifier("agents-secret-value")
            HStack(spacing: Pixels(8)) {
                Button("Save") { saveSecret() }.disabled(!canSave).accessibilityIdentifier("agents-secret-save")
                Button("Cancel") { closeSecretForm() }.accessibilityIdentifier("agents-secret-cancel")
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("agents-secret-form")
    }

    private func openSecretForm() {
        let agents = secretAgents
        guard let first = agents.first else { return }
        let preferred = workspace.settings.defaultAgentID.flatMap { id in agents.first { $0.id == id } } ?? first
        secretValue = ""
        secretDraft = SecretDraft(agent: preferred.id)
        secretNotice = nil; failure = nil
    }

    /// Clears the typed value and closes the form. Nothing of the value is kept.
    private func closeSecretForm() {
        secretValue = ""
        secretDraft = nil
    }

    private func saveSecret() {
        guard let draft = secretDraft, Self.isValidSecretName(draft.name), !secretValue.isEmpty,
              secretAgents.contains(where: { $0.id == draft.agent }) else { return }
        // Take the value out of state first: the field is empty and the form closed before the Keychain is touched.
        let value = secretValue
        closeSecretForm()
        do {
            let replaced = try workspace.saveSecret(value, agent: draft.agent, name: draft.name)
            secretNotice = replaced ? "Replaced \(draft.name)." : "Saved \(draft.name)."
            failure = nil
        } catch {
            failure = "Could not save: \(error.localizedDescription)"
            secretNotice = nil
        }
        reloadSecrets()
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
