import AlloyCore
import MetalUI

/// "N colour pairs are hard to read" (singular: "1 colour pair is hard to read").
func colourPairsText(_ count: Int) -> String {
    count == 1 ? "1 colour pair is hard to read" : "\(count) colour pairs are hard to read"
}

/// The strip above the chat for a theme preview (`theme-preview-bar`: Keep and Discard, plus the contrast findings) and
/// for an activation held back by the contrast warning (`theme-activation-warning`: Use anyway and Cancel). Draws nothing
/// when neither applies. Theme tokens only.
struct ThemeBar: Component {
    let themes: ThemeController
    /// A Keep that could not save, or an activation that failed; shown inline.
    /// Each error remembers what it was for and shows only while that is still on screen, so a newer preview or a
    /// different pending warning never inherits the old message.
    struct Failure<Subject: Equatable>: Equatable { var subject: Subject; var message: String }
    @State var keepFailure: Failure<ThemePreview>?
    @State var activationFailure: Failure<PendingActivation>?

    var content: some ElementGroup {
        let themes = themes
        VStack(spacing: 0) {
            if let preview = themes.preview {
                VStack(alignment: .leading, spacing: Pixels(4)) {
                    HStack(spacing: Pixels(8)) {
                        Text(verbatim: "Previewing \(preview.name)").font(size: 12).foregroundColor(.textPrimary).lineLimit(1)
                        Spacer()
                        Button("Keep") { keep() }.accessibilityIdentifier("theme-preview-keep")
                        Button("Discard") { keepFailure = nil; themes.discardPreview() }
                            .accessibilityIdentifier("theme-preview-discard")
                    }
                    if let keepError = keepFailure.flatMap({ $0.subject == preview ? $0.message : nil }) {
                        Text(verbatim: keepError).font(size: 11).foregroundColor(.errorInk)
                            .accessibilityIdentifier("theme-preview-error")
                    }
                }
                .padding(inset(10, 6))
                .frame(maxWidth: .infinity)
                .background(.commandTint)
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("theme-preview-bar")
                if !preview.findings.isEmpty {
                    HStack(spacing: Pixels(6)) {
                        Text(verbatim: colourPairsText(preview.findings.count)).font(size: 12).foregroundColor(.warningInk)
                        Spacer()
                    }
                    .padding(inset(10, 4))
                    .frame(maxWidth: .infinity)
                    .background(.warningTint)
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("theme-preview-findings")
                }
            }
            if let pending = themes.pendingActivation {
                VStack(alignment: .leading, spacing: Pixels(4)) {
                    HStack(spacing: Pixels(8)) {
                        Text(verbatim: colourPairsText(pending.findingCount)).font(size: 12).foregroundColor(.textPrimary).lineLimit(1)
                        Spacer()
                        Button("Use anyway") { use() }.accessibilityIdentifier("theme-activation-use")
                        Button("Cancel") { activationFailure = nil; themes.cancelActivation() }
                            .accessibilityIdentifier("theme-activation-cancel")
                    }
                    if let activationError = activationFailure.flatMap({ $0.subject == pending ? $0.message : nil }) {
                        Text(verbatim: activationError).font(size: 11).foregroundColor(.errorInk)
                            .accessibilityIdentifier("theme-activation-error")
                    }
                }
                .padding(inset(10, 6))
                .frame(maxWidth: .infinity)
                .background(.warningTint)
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("theme-activation-warning")
            }
        }
    }

    private func keep() {
        let themes = themes
        guard let subject = themes.preview else { return }
        Task {
            do { try await themes.keepPreview(); keepFailure = nil } catch {
                keepFailure = Failure(subject: subject, message: "Could not keep the theme: \(error.localizedDescription)")
            }
        }
    }

    private func use() {
        let subject = themes.pendingActivation
        do { try themes.confirmActivation(); activationFailure = nil } catch {
            activationFailure = subject.map { Failure(subject: $0, message: "Could not switch the theme: \(error.localizedDescription)") }
        }
    }
}
