import AlloyCore
import Foundation
import MetalUI

/// What the composer accepts by drop: image bytes of a format MetalUI names, or a file URL.
private enum ComposerDrop: Transferable {
    case image(Data, ContentType)
    case file(URL)

    func exportedContentTypes() -> [ContentType] { [] }
    static func importedContentTypes() -> [ContentType] { [.fileURL, .png, .tiff, .jpeg] }
    func exported(as contentType: ContentType) -> Data? { nil }
    init?(importing data: Data, contentType: ContentType) {
        if contentType == .fileURL {
            guard let url = URL(string: String(decoding: data, as: UTF8.self)), url.isFileURL else { return nil }
            self = .file(url)
        } else {
            guard !data.isEmpty else { return nil }
            self = .image(data, contentType)
        }
    }
}

/// The toolbar (mode, model, Stop, queued count) above the message field and Send button. Return sends (steering a
/// running turn), ⌥Return queues, ⇧Return adds a line, ⌘Return sends, ⇧Tab cycles the mode, Esc interrupts.
struct ComposerView: Component {
    let workspace: Workspace
    let session: Session
    /// Owned by the session's ``SessionUIStore`` entry, so the draft and any running encode survive a session switch.
    let model: ComposerModel
    /// The window's clipboard, read by the paste validator to let a text paste through to the field (G10).
    @Environment(\.clipboard) var clipboard
    @FocusState var fieldFocused: Bool

    var content: some ElementGroup {
        let workspace = workspace, sessionID = session.id, model = model, session = session
        let working = session.status == .working || session.status == .awaitingPermission
        let mode = Binding<PermissionMode>(get: { model.mode }, set: { model.setMode($0) })
        let draft = Binding<String>(get: { model.draft }, set: { model.draft = $0 })
        let open = Binding<Bool>(get: { model.suggestionsVisible }, set: { _ in })
        let clipboard = clipboard
        let caret = Binding<Range<Int>?>(get: { model.caret }, set: { if model.caret != $0 { model.caret = $0 } })
        let pickerOpen = Binding<Bool>(get: { session.requestModelPicker }, set: { session.requestModelPicker = $0 })
        VStack(alignment: .leading, spacing: Pixels(6)) {
            HStack(spacing: Pixels(8)) {
                Picker("Mode", selection: mode) {
                    ForEach(PermissionMode.allCases, id: \.self) { m in
                        Text(m.displayName).tag(m)
                    }
                }
                .accessibilityIdentifier("mode-picker")
                Menu(session.model ?? "Model") {
                    Button("Sonnet") { model.setModel("sonnet") }
                        .accessibilityIdentifier("model-choice-sonnet")
                    Button("Opus") { model.setModel("opus") }
                        .accessibilityIdentifier("model-choice-opus")
                    Button("Haiku") { model.setModel("haiku") }
                        .accessibilityIdentifier("model-choice-haiku")
                }
                .menuPresented(pickerOpen)   // `/model` with no name opens it (G9)
                .accessibilityIdentifier("model-menu")
                if working {
                    Button("Stop") { Task { await workspace.interrupt(sessionID) } }
                        .accessibilityIdentifier("stop")
                }
                if !session.queued.isEmpty {
                    Text("\(session.queued.count) queued").foregroundColor(.mutedInk)
                        .accessibilityIdentifier("queued-count")
                }
            }
            if !model.attachments.isEmpty || model.pending > 0 {
                HStack(spacing: Pixels(8)) {
                    if model.pending > 0 {
                        Text("Encoding image\u{2026}").foregroundColor(.mutedInk)
                            .accessibilityIdentifier("attachment-pending")
                    }
                    ForEach(model.attachments) { attachment in
                        HStack(spacing: Pixels(4)) {
                            Text(Self.chipLabel(attachment)).foregroundColor(.mutedInk)
                                .accessibilityIdentifier("attachment-chip-\(attachment.id.uuidString)")
                            Button("\u{00D7}") { model.removeAttachment(attachment.id) }
                                .accessibilityIdentifier("attachment-remove-\(attachment.id.uuidString)")
                        }
                    }
                }
            }
            HStack(alignment: .bottom, spacing: Pixels(8)) {
                TextField("Message Claude", text: draft, selectedOffsets: caret, prompt: Text("Message Claude").foregroundColor(.mutedInk), axis: .vertical)
                    .lineLimit(1...8)
                    .accessibilityIdentifier("composer")
                    .focused($fieldFocused)
                    .onChange(of: fieldFocused) { _, new in model.hasFocus = new }
                    .onChange(of: model.focusRequest) { _, _ in fieldFocused = true }
                    .onDisappear { model.hasFocus = false }
                    .onKeyPress(phases: [.down, .repeat]) { press in model.handleKey(press) }
                    // ⌘V is offered here before the field (G10). The validator declines whenever the clipboard also holds
                    // text, so text pastes (and a spreadsheet's text+image) still reach the field: text wins.
                    .pasteDestination(for: ImageData.self, action: { images in
                        for image in images { model.attach(imageData: image.data, typeHint: image.contentType.identifier) }
                    }, validator: { clipboard.hasContent(of: .text) ? [] : $0 })
                    // G18: the field grows from one line to eight (wrapped lines count), then scrolls inside.
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .padding(inset(8, 6))
                    .background(Color.surface)
                    .cornerRadius(Pixels(6))
                    .border(Color.controlBorder, width: Pixels(1))
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("composer-box")
                    .suggestionOverlay(isPresented: open, edge: .top, alignment: .leading) {
                        SuggestionList(items: model.suggestions?.items ?? [], selected: model.suggestions?.selected ?? 0) {
                            model.acceptSuggestion(at: $0)
                        }
                    }
                if session.status == .dormant {
                    Button("Resume") { Task { await workspace.wake(sessionID) } }
                        .accessibilityIdentifier("resume")
                }
                Button("Send") { model.send(priority: model.defaultPriority) }
                    .keyboardShortcut(.return)
                    .accessibilityIdentifier("send")
            }
            if let message = model.error {
                Text(message).foregroundColor(.errorInk).accessibilityIdentifier("composer-error")
            }
        }
        .dropDestination(for: ComposerDrop.self) { drops, _ in
            var files: [URL] = []
            for drop in drops {
                switch drop {
                case .image(let data, let type): model.attach(imageData: data, typeHint: type.identifier)
                case .file(let url): files.append(url)
                }
            }
            model.handleDrop(fileURLs: files)
            return true
        }
        .padding(inset(12, 10))
    }

    /// "640×480 · 1.2 MB".
    static func chipLabel(_ attachment: ImageAttachment) -> String {
        let size = ByteCountFormatter.string(fromByteCount: Int64(attachment.byteCount), countStyle: .file)
        guard let (w, h) = attachment.pixelSize else { return size }
        return "\(w)\u{00D7}\(h) \u{00B7} \(size)"
    }
}

