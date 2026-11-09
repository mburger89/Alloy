import AlloyCore
import Foundation
import MetalUI

/// Every app-wide setting, in a full-panel view over the chat column (`settings-view`). Closes on the close button
/// (`settings-close`) or Esc. The toggles save at once; the Claude path saves with Save.
struct SettingsView: Component {
    let workspace: Workspace
    let close: @MainActor () -> Void
    @State var path = ""
    @State var loaded = false
    @State var failure: String?
    @State var saved = false
    @State var showDetected = false
    @FocusState var focused: Bool

    var content: some ElementGroup {
        let workspace = workspace
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
                Text("Shared knowledge").font(size: 12).foregroundColor(.mutedInk)
                Toggle(isOn: flag(\.shareKnowledge)) { Text("Share knowledge between sessions").font(size: 13) }
                    .accessibilityIdentifier("settings-share-knowledge")
                Toggle(isOn: flag(\.askBeforeSharedNotes)) { Text("Ask before sessions use Alloy's tools").font(size: 13) }
                    .accessibilityIdentifier("settings-ask-shared-notes")
                Text("Running sessions pick up a change when they are next idle.").font(size: 11).foregroundColor(.mutedInk)
                Button("Back to defaults") { resetKnowledge() }.accessibilityIdentifier("settings-reset")
            }
            if saved {
                Text("Saved").font(size: 12).foregroundColor(.mutedInk).accessibilityIdentifier("settings-saved")
            }
            if let failure {
                Text(failure).font(size: 12).foregroundColor(.errorInk)
                    .accessibilityIdentifier("settings-error")
            }
            Spacer()
        }
        .padding(Pixels(20))
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
