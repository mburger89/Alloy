import AlloyCore
import MetalUI

/// The git part of Settings: three toggles and the path of the git executable. The toggles save at once through
/// `updateSettings`; the path saves on Return and takes effect after a restart.
struct GitSettingsSection: Component {
    let workspace: Workspace
    @State var path = ""
    @State var loaded = false
    @State var failure: String?

    var content: some ElementGroup {
        let workspace = workspace
        VStack(alignment: .leading, spacing: Pixels(8)) {
            Text("Git").font(size: 12).foregroundColor(.mutedInk)
            Toggle(isOn: flag(\.gutterMarks)) { Text("Change marks in the gutter").font(size: 13) }
                .accessibilityIdentifier("settings-git-gutter-marks")
            Toggle(isOn: flag(\.statusColours)) { Text("Status colours in the file tree").font(size: 13) }
                .accessibilityIdentifier("settings-git-status-colours")
            Toggle(isOn: flag(\.liveMarks)) { Text("Update marks while typing").font(size: 13) }
                .disabled(!workspace.settings.git.gutterMarks)
                .accessibilityIdentifier("settings-git-live-marks")
            Text("Marks otherwise update when you save.").font(size: 11).foregroundColor(.mutedInk)
            Text("Path to git").font(size: 12).foregroundColor(.mutedInk)
            TextField("Auto-detect", text: $path)
                .onSubmit { savePath() }
                .accessibilityIdentifier("settings-git-path")
            Text("Takes effect after restart.").font(size: 11).foregroundColor(.mutedInk)
            Text("The commit message draft is stored unencrypted in Alloy's per-project UI state file.")
                .font(size: 11).foregroundColor(.mutedInk).accessibilityIdentifier("settings-git-draft-note")
            if let failure {
                Text(verbatim: failure).font(size: 11).foregroundColor(.errorInk).accessibilityIdentifier("settings-git-error")
            }
        }
        .onAppear { if !loaded { loaded = true; path = workspace.settings.git.gitPath } }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("settings-git-section")
    }

    private func flag(_ key: WritableKeyPath<GitSettings, Bool>) -> Binding<Bool> {
        let workspace = workspace
        return Binding(get: { workspace.settings.git[keyPath: key] },
                       set: { value in
                           var s = workspace.settings
                           s.git[keyPath: key] = value
                           apply(s)
                       })
    }

    private func savePath() {
        var s = workspace.settings
        s.git.gitPath = path.trimmingCharacters(in: .whitespacesAndNewlines)
        apply(s)
    }

    private func apply(_ s: AlloySettings) {
        do { try workspace.updateSettings(s); failure = nil } catch { failure = "Could not save: \(error.localizedDescription)" }
    }
}
