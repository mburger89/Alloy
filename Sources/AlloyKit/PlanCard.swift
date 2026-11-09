import AlloyCore
import Foundation
import MetalUI

/// An ExitPlanMode prompt: the plan, then Approve, Approve with accept-edits, or Send back with feedback.
/// The feedback editor's open flag and text live in a `CardDraft` owned by the transcript (see `TranscriptView.drafts`).
struct PlanCard: Component {
    let workspace: Workspace
    let sessionID: Session.ID
    let block: PlanBlock
    /// The unsent feedback, held by the transcript so it outlives this row.
    let draft: Binding<CardDraft>
    /// The transcript's parsed Markdown, shared by the rows.
    let cache: MarkdownCache
    private var sendBackOpen: Bool { draft.wrappedValue.sendBackOpen }
    private var feedbackBinding: Binding<String> {
        Binding(get: { draft.wrappedValue.feedback }, set: { draft.wrappedValue.feedback = $0 })
    }

    var content: some ElementGroup {
        BlockChrome(kind: .plan, title: "Plan", id: "plan-\(block.requestID)") {
            MarkdownText(blockID: "plan-\(block.requestID)", text: block.plan, cache: cache)
            if let path = block.planFilePath, !path.isEmpty {
                Text(verbatim: path).font(family: "Menlo", size: 11).foregroundColor(.mutedInk)
            }
            switch block.state {
            case .pending: actions
            case .answered: Text("Approved").font(size: 12).foregroundColor(.mutedInk)
            case .sentBack:
                Text(verbatim: block.feedback.map { "Sent back: \($0)" } ?? "Sent back")
                    .font(size: 12).foregroundColor(.mutedInk)
            case .cancelled: Text("Cancelled").font(size: 12).foregroundColor(.mutedInk)
            }
        }
    }

    @ElementBuilder
    private var actions: some ElementGroup {
        let requestID = block.requestID
        VStack(alignment: .leading, spacing: Pixels(6)) {
            HStack(spacing: Pixels(8)) {
                Button("Approve") { approve(.default_) }
                    .accessibilityIdentifier("plan-approve-\(requestID)")
                Button("Approve, accept edits") { approve(.acceptEdits) }
                    .accessibilityIdentifier("plan-approve-edits-\(requestID)")
                Button("Send back") { draft.wrappedValue.sendBackOpen = true }
                    .accessibilityIdentifier("plan-sendback-\(requestID)")
            }
            if sendBackOpen {
                TextEditor("What should change?", text: feedbackBinding)
                    .frame(maxWidth: .infinity, minHeight: Pixels(48), maxHeight: Pixels(140))
                    .accessibilityIdentifier("plan-feedback-\(requestID)")
                HStack(spacing: 0) {
                    Spacer()
                    Button("Send") { sendBack() }
                        .accessibilityIdentifier("plan-send-\(requestID)")
                }
            }
        }
    }

    private func approve(_ mode: PermissionMode) {
        let workspace = workspace, sessionID = sessionID, requestID = block.requestID
        Task { await workspace.answerPlan(session: sessionID, requestID: requestID, approve: true, modeAfter: mode, feedback: nil) }
    }

    private func sendBack() {
        let workspace = workspace, sessionID = sessionID, requestID = block.requestID, text = draft.wrappedValue.feedback
        Task {
            await workspace.answerPlan(session: sessionID, requestID: requestID, approve: false, modeAfter: .default_,
                                       feedback: text)
        }
    }
}
