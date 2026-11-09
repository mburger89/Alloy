import AlloyCore
import Foundation
import MetalUI

/// An AskUserQuestion prompt: per question a header chip, the question text, one row per option and an "Other" row
/// with a text field. Submit sends every answer through `Workspace.answerQuestion`; once answered the chosen
/// answers show read-only. The picks live in a `CardDraft` owned by the transcript (see `TranscriptView.drafts`).
struct QuestionCard: Component {
    typealias Question = QuestionBlock.Question

    let workspace: Workspace
    let sessionID: Session.ID
    let block: QuestionBlock
    /// The unsent picks, held by the transcript so they outlive this row.
    let draft: Binding<CardDraft>
    private var picked: [Int: Set<Int>] { draft.wrappedValue.picked }
    private var otherText: [Int: String] { draft.wrappedValue.otherText }
    @FocusState var focusedOther: Int?

    var content: some ElementGroup {
        BlockChrome(kind: .question, title: "Question", id: "q-\(block.requestID)") {
            switch block.state {
            case .pending: pending
            case .cancelled: Text("Cancelled").font(size: 12).foregroundColor(.mutedInk)
            case .answered, .sentBack: answered
            }
        }
    }

    // MARK: Pending

    @ElementBuilder
    private var pending: some ElementGroup {
        let requestID = block.requestID
        VStack(alignment: .leading, spacing: Pixels(10)) {
            ForEach(Array(block.questions.enumerated()), id: \.offset) { qi, question in
                questionView(qi, question)
            }
            HStack(spacing: 0) {
                Spacer()
                Button("Submit") { submit() }
                    .disabled(!allAnswered)
                    .accessibilityIdentifier("q-submit-\(requestID)")
            }
        }
    }

    @ElementBuilder
    private func questionView(_ qi: Int, _ question: Question) -> some ElementGroup {
        let requestID = block.requestID
        VStack(alignment: .leading, spacing: Pixels(4)) {
            HStack(spacing: Pixels(6)) {
                Text(verbatim: question.header).font(size: 11).foregroundColor(.questionInk)
                    .padding(inset(6, 1))
                    .background(Color.questionInk.opacity(0.14))
                    .cornerRadius(Pixels(6))
                Text(verbatim: question.question).font(size: 13)
                Spacer()
            }
            ForEach(Array(question.options.enumerated()), id: \.offset) { oi, option in
                optionRow(qi, oi, multi: question.multiSelect, id: "q-opt-\(requestID)-\(qi)-\(oi)") {
                    VStack(alignment: .leading, spacing: 0) {
                        Text(verbatim: option.label).font(size: 12)
                        if !option.description.isEmpty {
                            Text(verbatim: option.description).font(size: 11).foregroundColor(.mutedInk)
                        }
                    }
                }
            }
            optionRow(qi, question.options.count, multi: question.multiSelect, id: "q-other-row-\(requestID)-\(qi)") {
                TextField("Other", text: otherBinding(qi, question))
                    .focused($focusedOther, equals: qi)
                    .accessibilityIdentifier("q-other-\(requestID)-\(qi)")
            }
        }
    }

    @ElementBuilder
    private func optionRow<Label: ElementGroup>(_ qi: Int, _ oi: Int, multi: Bool, id: String,
                                                @ElementBuilder label: () -> Label) -> some ElementGroup {
        let on = picked[qi]?.contains(oi) ?? false
        let symbol = multi ? (on ? "checkmark.square.fill" : "square") : (on ? "largecircle.fill.circle" : "circle")
        HStack(spacing: Pixels(8)) {
            Image(systemName: symbol).font(.system(size: 12)).foregroundColor(on ? .questionInk : .mutedInk)
                .accessibilityHidden(true)
            label()
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(inset(6, 3))
        .background(on ? Color.questionInk.opacity(0.10) : Color.clear)
        .cornerRadius(Pixels(6))
        .onTapGesture {
            // The Other row focuses its field; typing selects it.
            if oi == block.questions[qi].options.count { focusedOther = qi } else { toggle(qi, oi, multi: multi) }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(id)
    }

    private func otherBinding(_ qi: Int, _ question: Question) -> Binding<String> {
        Binding(get: { otherText[qi] ?? "" }, set: { text in
            draft.wrappedValue.otherText[qi] = text
            select(qi, question.options.count, multi: question.multiSelect, on: !text.isEmpty)
        })
    }

    private func toggle(_ qi: Int, _ oi: Int, multi: Bool) {
        let on = picked[qi]?.contains(oi) ?? false
        select(qi, oi, multi: multi, on: multi ? !on : true)
    }

    private func select(_ qi: Int, _ oi: Int, multi: Bool, on: Bool) {
        var set = multi ? (picked[qi] ?? []) : []
        if on { set.insert(oi) } else { set.remove(oi) }
        draft.wrappedValue.picked[qi] = set
    }

    // MARK: Answers

    /// The answer text for question `qi`: picked labels in option order, then the "Other" text; nil when empty.
    private func answer(_ qi: Int) -> String? {
        let question = block.questions[qi]
        let set = picked[qi] ?? []
        var parts = question.options.indices.filter { set.contains($0) }.map { question.options[$0].label }
        if set.contains(question.options.count) {
            let text = (otherText[qi] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { parts.append(text) }
        }
        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }

    private var allAnswered: Bool { block.questions.indices.allSatisfy { answer($0) != nil } }

    private func submit() {
        guard allAnswered else { return }
        var answers: [String: String] = [:]
        for qi in block.questions.indices { answers[block.questions[qi].question] = answer(qi) }
        let workspace = workspace, sessionID = sessionID, requestID = block.requestID
        // Answers are keyed by question text: the AskUserQuestion wire format has no other key.
        Task { await workspace.answerQuestion(session: sessionID, requestID: requestID, answers: answers) }
    }

    // MARK: Answered

    @ElementBuilder
    private var answered: some ElementGroup {
        VStack(alignment: .leading, spacing: Pixels(6)) {
            ForEach(Array(block.questions.enumerated()), id: \.offset) { _, question in
                VStack(alignment: .leading, spacing: Pixels(2)) {
                    Text(verbatim: question.question).font(size: 12).foregroundColor(.mutedInk)
                    Text(verbatim: block.answers[question.question] ?? "").font(size: 13)
                }
            }
        }
    }
}

/// The unsent local state of a question or plan card, by request id (see `TranscriptView.drafts`).
struct CardDraft: Equatable {
    /// Picked option indices per question; the "Other" row is index `options.count`.
    var picked: [Int: Set<Int>] = [:]
    var otherText: [Int: String] = [:]
    var sendBackOpen = false
    var feedback = ""
}
