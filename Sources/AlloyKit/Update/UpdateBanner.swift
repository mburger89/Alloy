import Foundation
import MetalUI

/// The sidebar row shown while an update waits to install: "Alloy <v> is ready" with Restart to update and the notes.
/// A child of its own that reads only `UpdateModel`, so the sidebar does not re-run when the model changes (or per keystroke).
struct UpdateBanner: Component {
    let model: UpdateModel

    var content: some ElementGroup {
        let _ = BodyProbe.hit("UpdateBanner")
        let model = model
        if let version = model.readyVersion {
            VStack(alignment: .leading, spacing: Pixels(6)) {
                Text("Alloy \(version) is ready").font(size: 12)
                    .accessibilityIdentifier("update-banner-title")
                if model.confirmingRestart {
                    Text(model.busySessionCount == 1 ? "A session is still working. Restarting stops it."
                         : "\(model.busySessionCount) sessions are still working. Restarting stops them.")
                        .font(size: 11).foregroundColor(.mutedInk)
                        .accessibilityIdentifier("update-restart-confirm-text")
                    HStack(spacing: Pixels(8)) {
                        Button("Restart anyway") { model.confirmRestart() }.accessibilityIdentifier("update-restart-confirm")
                        Button("Cancel") { model.cancelRestart() }.accessibilityIdentifier("update-restart-cancel")
                    }
                } else {
                HStack(spacing: Pixels(8)) {
                    Button("Restart to update") { model.restartToUpdate() }
                        .accessibilityIdentifier("update-restart")
                    if model.notes != nil {
                        Button("Release notes") { model.showingNotes = true }
                            .accessibilityIdentifier("update-show-notes")
                    }
                }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(inset(10, 8))
            .background(.warningTint)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("update-banner")
        }
    }
}

extension UpdateBanner: Equatable {
    nonisolated static func == (a: Self, b: Self) -> Bool { a.model === b.model }
}

/// The release notes over the chat column, like Settings: Markdown through the transcript's renderer.
struct UpdateNotesOverlay: Component {
    let model: UpdateModel
    @State var cache = MarkdownCache()

    var content: some ElementGroup {
        let model = model
        if model.showingNotes, let notes = model.notes {
            VStack(alignment: .leading, spacing: Pixels(10)) {
                HStack(spacing: 0) {
                    Text(title).font(size: 16).accessibilityIdentifier("update-notes-title")
                    Spacer()
                    Button { model.showingNotes = false } label: {
                        Image(systemName: "xmark").font(.system(size: 13)).padding(Pixels(4))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Close release notes")
                    .accessibilityIdentifier("update-notes-close")
                }
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        MarkdownText(blockID: "update-notes", text: notes, cache: cache)
                    }
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("update-notes-body")
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .padding(Pixels(20))
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(.panelFill)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Release notes")
            .accessibilityIdentifier("update-notes")
        }
    }

    private var title: String {
        switch model.state {
        case .readyToInstall(let v), .available(let v, _): "What's new in Alloy \(v)"
        default: "What's new"
        }
    }
}

/// Settings: automatic checks, the last check and "Check for Updates…".
struct UpdatesSection: Component {
    let model: UpdateModel

    var content: some ElementGroup {
        let model = model
        VStack(alignment: .leading, spacing: Pixels(8)) {
            Text("Updates").font(size: 12).foregroundColor(.mutedInk)
            Toggle(isOn: Binding(get: { model.automaticChecks }, set: { model.setAutomaticChecks($0) })) {
                Text("Check for updates automatically").font(size: 13)
            }
            .accessibilityIdentifier("settings-update-automatic")
            Text(Self.status(model)).font(size: 11).foregroundColor(model.lastFailure == nil ? .mutedInk : .errorInk)
                .accessibilityIdentifier("settings-update-status")
            Text(Self.lastChecked(model)).font(size: 11).foregroundColor(.mutedInk)
                .accessibilityIdentifier("settings-update-last-checked")
            Button("Check for Updates\u{2026}") { model.checkForUpdates() }
                .disabled(model.isBusy)
                .accessibilityIdentifier("settings-update-check")
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("settings-update-section")
    }

    static func time(_ date: Date) -> String { date.formatted(date: .abbreviated, time: .shortened) }

    static func lastChecked(_ model: UpdateModel) -> String {
        model.lastCheck.map { "Last checked \(time($0))" } ?? "Not checked yet"
    }

    static func status(_ model: UpdateModel) -> String {
        if let failed = model.lastFailure, !model.isBusy, model.readyVersion == nil {
            return "Couldn\u{2019}t check for updates (\(time(failed)))"
        }
        switch model.state {
        case .idle: return model.lastCheck == nil ? "" : "Alloy is up to date"
        case .checking: return "Checking\u{2026}"
        case .available(let v, _): return "Alloy \(v) is available"
        case .downloading(let p): return p.map { "Downloading\u{2026} \(Int($0 * 100))%" } ?? "Downloading\u{2026}"
        case .readyToInstall(let v): return "Alloy \(v) is ready to install"
        case .error: return "Couldn\u{2019}t check for updates"
        }
    }
}
