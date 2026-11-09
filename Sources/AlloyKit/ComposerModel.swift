import AlloyCore
import Foundation
import MetalUI
import Observation

/// What the open `/` or `@` list shows: the token being completed, the filtered items and the highlighted row.
struct SuggestionState: Equatable {
    enum Kind: Equatable { case slash, file }
    struct Item: Equatable, Identifiable {
        var id: String
        var title: String
        var detail: String?
    }

    var kind: Kind
    var query: String
    var items: [Item]
    var selected: Int
    var tokenRange: Range<String.Index>
}

/// The model behind one session's composer: the draft, its keys, and the mode and model controls.
@MainActor @Observable
final class ComposerModel {
    /// Whether the message field holds the keyboard focus, kept by the view; Settings reads it on open.
    @ObservationIgnored var hasFocus = false
    /// Bumped to ask the view to take the keyboard focus back (Settings closing).
    var focusRequest = 0
    @ObservationIgnored let workspace: Workspace
    @ObservationIgnored let sessionID: Session.ID
    var draft = "" {
        didSet {
            guard draft != oldValue, !batching else { return }
            awaitingCaret = true
            draftChanged()
        }
    }
    /// The editor's selection as `Character` offsets into ``draft`` (`TextEditor(selectedOffsets:)`, G11); empty is the
    /// caret and `nil` is unknown (the end of the draft is used). The editor writes it after the input that moved it,
    /// which for typing is after the text change, so a caret move re-reads the token once per edit.
    var caret: Range<Int>? {
        didSet {
            guard caret != oldValue, !batching else { return }
            // Only a list that is open, or an edit that has not yet seen its caret, re-reads: moving the caret after Esc
            // must not reopen the list.
            if suggestions != nil || awaitingCaret { awaitingCaret = false; draftChanged() }
        }
    }
    /// Set while ``replaceDraft(_:caret:)`` writes both values, so the list is read once, with the new caret.
    @ObservationIgnored private var batching = false
    /// A draft edit whose caret write has not arrived yet.
    @ObservationIgnored private var awaitingCaret = false
    /// Pasted or dropped images (Task 11).
    var attachments: [ImageAttachment] = []
    /// The inline error under the composer (`composer-error`); clears itself after ``errorDuration``.
    var error: String?
    /// Images still encoding; a send waits for them (``deferredSend``).
    var pending = 0
    /// Returns pressed while images were encoding: the trimmed text and priority at that moment, in order.
    @ObservationIgnored private var deferredSends: [(text: String, priority: Priority?)] = []
    @ObservationIgnored var imageLimit = ImageEncoding.maxBytes
    @ObservationIgnored private var errorTask: Task<Void, Never>?
    @ObservationIgnored var errorDuration: Duration = .seconds(5)
    /// The open `/` or `@` list (Task 12); while non-nil it gets ↑ ↓ Return Tab Esc first.
    var suggestions: SuggestionState?
    /// Relative project paths, loaded once from the workspace's ``FileIndex`` when a file list first opens.
    @ObservationIgnored private var filePaths: [String] = []
    @ObservationIgnored private var indexLoad: Task<Void, Never>?
    @ObservationIgnored private var filterTask: Task<Void, Never>?
    @ObservationIgnored private var indexLoading = false
    /// The query the file rows were computed for.
    @ObservationIgnored private var filesResultQuery: String?
    /// Most rows the list shows.
    nonisolated static let suggestionLimit = 50

    init(workspace: Workspace, sessionID: Session.ID) {
        self.workspace = workspace
        self.sessionID = sessionID
    }

    // MARK: Images and file drops (Task 11)

    func showError(_ text: String) {
        error = text
        errorTask?.cancel()
        let duration = errorDuration
        errorTask = Task { [weak self] in
            try? await Task.sleep(for: duration)
            guard !Task.isCancelled else { return }
            self?.error = nil
        }
    }

    /// Adds pasted or dropped image bytes as a chip; a refused image shows its error instead. Encoding runs off the
    /// main actor; ``send(priority:)`` waits for it.
    func attach(imageData data: Data, typeHint: String?) {
        let limit = imageLimit
        encode { () throws(ImageError) in try ImageEncoding.attachment(from: data, typeHint: typeHint, limit: limit) }
    }

    /// Runs `work` detached, then appends its chip or shows its error on the main actor.
    private func encode(_ work: @escaping @Sendable () throws(ImageError) -> ImageAttachment) {
        pending += 1
        // Strong on purpose: the model is owned by its session's UI entry, so there is no cycle, and an encode that
        // outlives the visible composer (a session switch) must still deliver its deferred send.
        Task.detached {
            let result: Result<ImageAttachment, ImageError>
            do throws(ImageError) { result = .success(try work()) } catch { result = .failure(error) }
            await self.finishEncode(result)
        }
    }

    private func finishEncode(_ result: Result<ImageAttachment, ImageError>) {
        switch result {
        case .success(let attachment): attachments.append(attachment)
        case .failure(let error): showError(error.message)
        }
        pending -= 1
        if pending == 0, !deferredSends.isEmpty {
            let queued = deferredSends
            deferredSends = []
            // The first snapshot carries every attachment (an encode that failed just left its chip out).
            for (i, item) in queued.enumerated() {
                let images = i == 0 ? attachments : []
                guard !item.text.isEmpty || !images.isEmpty else { continue }
                dispatch(OutgoingMessage(text: item.text, images: images, priority: item.priority))
            }
            attachments = []
        }
    }

    func removeAttachment(_ id: ImageAttachment.ID) { attachments.removeAll { $0.id == id } }

    /// Dropped files: an image file becomes a chip, a file in the project an `@<relative path> ` mention, and any
    /// other file its absolute path. Non-file URLs are ignored.
    func handleDrop(fileURLs: [URL]) {
        let root = workspace.projectRoot.resolvingSymlinksInPath().standardizedFileURL.path
        let prefix = root.hasSuffix("/") ? root : root + "/"
        let limit = imageLimit
        for url in fileURLs where url.isFileURL {
            let file = url.resolvingSymlinksInPath().standardizedFileURL
            if ImageEncoding.imageExtensions.contains(file.pathExtension.lowercased()) {
                encode { () throws(ImageError) in
                    let size = (try? file.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
                    if size > 4 * limit { throw .tooLarge(bytes: size) }
                    guard let data = try? Data(contentsOf: file) else { throw .unreadable }
                    return try ImageEncoding.attachment(from: data, typeHint: file.pathExtension, limit: limit)
                }
            } else if file.path.hasPrefix(prefix) {
                insertMention(Self.quoted("@", String(file.path.dropFirst(prefix.count))))
            } else {
                insertMention(Self.quoted("", file.path))
            }
        }
    }

    /// `@path` or `path`, double-quoted when it holds a space, as the CLI writes them.
    static func quoted(_ lead: String, _ path: String) -> String {
        path.contains(" ") ? "\(lead)\"\(path)\"" : lead + path
    }

    /// Sets the draft and the caret together (an external change moves the editor's caret only when told to, G11).
    private func replaceDraft(_ text: String, caret offset: Int) {
        batching = true
        draft = text
        caret = offset..<offset
        batching = false
        awaitingCaret = false
        draftChanged()
    }

    /// The caret as an index into the draft (clamped); the end when it is unknown. A selection counts by its upper end.
    private var caretIndex: String.Index {
        guard let caret else { return draft.endIndex }
        return draft.index(draft.startIndex, offsetBy: caret.upperBound, limitedBy: draft.endIndex) ?? draft.endIndex
    }

    /// Replaces `range` with `text` and a following space (none when whitespace already follows), then puts the caret
    /// after that space.
    private func replace(_ range: Range<String.Index>, with text: String) {
        var updated = draft
        let nextIsSpace = range.upperBound < updated.endIndex && updated[range.upperBound].isWhitespace
        let lower = updated.distance(from: updated.startIndex, to: range.lowerBound)
        updated.replaceSubrange(range, with: nextIsSpace ? text : text + " ")
        replaceDraft(updated, caret: lower + text.count + 1)
    }

    /// Inserts `text` and a space at the caret (the end when it is unknown), with a space before it unless the draft
    /// starts there or whitespace precedes it; the caret ends after the inserted text.
    func insertMention(_ text: String) {
        let at = caretIndex
        let needsLead = at > draft.startIndex && !draft[draft.index(before: at)].isWhitespace
        replace(at..<at, with: (needsLead ? " " : "") + text)
    }

    private var session: Session? { workspace.sessions.first { $0.id == sessionID } }

    /// What a plain Return sends with: a running turn is steered (`next`); an idle one just starts a turn.
    var defaultPriority: Priority? {
        switch session?.status {
        case .working, .awaitingPermission: .next
        default: nil
        }
    }

    func handleKey(_ press: KeyPress) -> KeyPress.Result {
        guard press.phase.contains(.down) || press.phase.contains(.repeat) else { return .ignored }
        return handleKey(press.key, modifiers: press.modifiers)
    }

    /// The key table. Separate from `KeyPress` because MetalUI builds those only from real events.
    func handleKey(_ key: KeyEquivalent, modifiers: EventModifiers) -> KeyPress.Result {
        // Ruling 2: an open suggestion list takes ↑ ↓ Return Tab Esc before the rules below.
        if suggestions != nil, handleSuggestionKey(key, modifiers: modifiers) { return .handled }
        switch key {
        case .return:
            // The G18 field submits on ⇧Return, so the newline is inserted here, before the field sees the key.
            if modifiers.contains(.shift) { insertNewline(); return .handled }
            send(priority: modifiers.contains(.option) ? .later : defaultPriority)
            return .handled
        case .escape:
            switch session?.status {
            case .working, .awaitingPermission:
                let workspace = workspace, id = sessionID
                Task { await workspace.interrupt(id) }
                return .handled
            default:
                return .ignored
            }
        case .tab where modifiers == .shift:
            cycleMode()
            return .handled
        default:
            return .ignored
        }
    }

    // MARK: Suggestions (Task 12)

    /// Whether the overlay shows: a list is open and has rows.
    var suggestionsVisible: Bool { suggestions.map { !$0.items.isEmpty } ?? false }

    /// Routes ↑ ↓ Return Tab Esc to the open list; true when the list took the key (Return on an exact slash match does not). An open list consumes all five, so
    /// Esc never falls through to interrupting a working turn. A list with no rows closes on Return instead, and the
    /// key sends.
    func handleSuggestionKey(_ key: KeyEquivalent, modifiers: EventModifiers) -> Bool {
        guard var state = suggestions else { return false }
        // A list with no rows shows nothing, so Esc and the arrows are not its to take.
        if state.items.isEmpty, key == .escape || key == .upArrow || key == .downArrow { return false }
        switch key {
        case .escape:
            suggestions = nil
            return true
        case .upArrow, .downArrow:
            guard !state.items.isEmpty else { return true }
            let step = key == .downArrow ? 1 : state.items.count - 1
            state.selected = (state.selected + step) % state.items.count
            suggestions = state
            return true
        case .return where modifiers.isEmpty, .tab where modifiers.isEmpty:
            guard !state.items.isEmpty else {
                suggestions = nil
                return key == .tab
            }
            // File rows for an older query are still showing; wait for the new results.
            if state.kind == .file, filesResultQuery != state.query { return true }
            // `/compact` typed in full: Return sends it now instead of accepting the row it already is. Tab still accepts.
            if key == .return, state.kind == .slash, state.items.indices.contains(state.selected),
               state.items[state.selected].id == state.query {
                suggestions = nil
                return false
            }
            acceptSuggestion(at: state.selected)
            return true
        default:
            return false
        }
    }

    /// Replaces the token with `/name ` or `@path ` (quoted when the path holds a space) and closes the list.
    func acceptSuggestion(at index: Int) {
        guard let state = suggestions, state.items.indices.contains(index) else { return }
        let item = state.items[index]
        let replacement = switch state.kind {
        case .slash: "/" + item.id + " "
        case .file: Self.quoted("@", item.id) + " "
        }
        suggestions = nil
        replace(state.tokenRange, with: String(replacement.dropLast()))
    }

    /// Replaces the selection (or inserts at the caret; the end when unknown) with a line break and puts the caret after it.
    func insertNewline() {
        let count = draft.count
        let range = caret.map { min($0.lowerBound, count)..<min($0.upperBound, count) } ?? count..<count
        var updated = draft
        let lower = updated.index(updated.startIndex, offsetBy: range.lowerBound)
        let upper = updated.index(updated.startIndex, offsetBy: range.upperBound)
        updated.replaceSubrange(lower..<upper, with: "\n")
        replaceDraft(updated, caret: range.lowerBound + 1)
    }

    /// The `/` or `@` token that ends at `caret` (the end of the draft when nil). `/` counts only as the draft's first
    /// character; `@` at the start or after whitespace, with `@"` running to the closing quote. Text after the caret is
    /// not part of the token.
    static func token(in draft: String, caret: String.Index? = nil) -> (kind: SuggestionState.Kind, query: String, range: Range<String.Index>)? {
        let stop = caret ?? draft.endIndex
        let head = draft[..<stop]
        if head.hasPrefix("/") {
            let rest = head.dropFirst()
            if !rest.contains(where: \.isWhitespace) { return (.slash, String(rest), draft.startIndex..<stop) }
            return nil
        }
        var end = head.endIndex
        while let at = head[..<end].lastIndex(of: "@") {
            end = at
            if at != head.startIndex, !head[head.index(before: at)].isWhitespace { continue }
            let rest = head[head.index(after: at)...]
            if rest.hasPrefix("\"") {
                let inner = rest.dropFirst()
                if !inner.contains("\"") { return (.file, String(inner), at..<stop) }
            } else if !rest.contains(where: \.isWhitespace) {
                return (.file, String(rest), at..<stop)
            }
        }
        return nil
    }

    private func draftChanged() {
        // A selection (not a caret) completes nothing.
        guard caret.map(\.isEmpty) ?? true, let token = Self.token(in: draft, caret: caretIndex) else {
            filterTask?.cancel()
            suggestions = nil
            return
        }
        var state = suggestions.flatMap { $0.kind == token.kind ? $0 : nil }
            ?? SuggestionState(kind: token.kind, query: token.query, items: [], selected: 0, tokenRange: token.range)
        let queryChanged = state.query != token.query
        state.query = token.query
        state.tokenRange = token.range
        if queryChanged { state.selected = 0 }
        switch token.kind {
        case .slash:
            filterTask?.cancel()
            let commands = session?.slashCommands ?? []
            let byName = Dictionary(commands.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
            state.items = FuzzyMatch.top(token.query, in: commands.map(\.name), limit: Self.suggestionLimit).compactMap { name in
                byName[name].map { c in
                    let detail = [c.description, c.argumentHint ?? ""].filter { !$0.isEmpty }.joined(separator: " ")
                    return SuggestionState.Item(id: name, title: "/" + name, detail: detail.isEmpty ? nil : detail)
                }
            }
            suggestions = state
        case .file:
            let isNewToken = suggestions?.kind != .file
            suggestions = state
            filterFiles(query: token.query, newToken: isNewToken)
        }
    }

    /// Scores the cached paths off the main actor (100k paths per keystroke is too much for it); the first call also
    /// loads the index. A result applies only if the draft's file token still has the same query.
    private func filterFiles(query: String, newToken: Bool) {
        filterTask?.cancel()
        let index = workspace.fileIndex
        // Each new `@` token rescans (files appear during a session); an empty cache is retried too.
        if !indexLoading, newToken || filePaths.isEmpty { indexLoad = nil }
        let load: Task<Void, Never>
        if let existing = indexLoad {
            load = existing
        } else {
            indexLoading = true
            load = Task { [weak self] in
                await index.refresh()
                let paths = await index.paths()
                self?.filePaths = paths
                self?.indexLoading = false
            }
            indexLoad = load
        }
        filterTask = Task { [weak self] in
            await load.value
            guard !Task.isCancelled, let paths = self?.filePaths else { return }
            let scoring = Task.detached(priority: .userInitiated) {
                FuzzyMatch.top(query, in: paths, limit: ComposerModel.suggestionLimit)
            }
            let top = await withTaskCancellationHandler { await scoring.value } onCancel: { scoring.cancel() }
            guard !Task.isCancelled, let self, var state = self.suggestions, state.kind == .file, state.query == query else { return }
            self.filesResultQuery = query
            state.items = top.map { SuggestionState.Item(id: $0, title: $0, detail: nil) }
            state.selected = min(state.selected, max(0, top.count - 1))
            self.suggestions = state
        }
    }

    /// Sends the trimmed draft (and attachments), then clears both. An empty draft with no attachments does nothing.
    func send(priority: Priority?) {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty || !attachments.isEmpty || pending > 0 else { return }
        replaceDraft("", caret: 0)
        suggestions = nil
        if pending > 0 { deferredSends.append((text, priority)); return }
        let message = OutgoingMessage(text: text, images: attachments, priority: priority)
        attachments = []
        dispatch(message)
    }

    private func dispatch(_ message: OutgoingMessage) {
        let workspace = workspace, id = sessionID
        Task { await workspace.send(message, to: id) }
    }

    var mode: PermissionMode {
        session?.permissionMode.flatMap(PermissionMode.init(rawValue:)) ?? .default_
    }

    func setMode(_ mode: PermissionMode) {
        let workspace = workspace, id = sessionID
        Task { await workspace.setPermissionMode(mode, for: id) }
    }

    /// default → acceptEdits → plan → default, as the CLI's ⇧Tab does; any other mode returns to default.
    func cycleMode() {
        switch mode {
        case .default_: setMode(.acceptEdits)
        case .acceptEdits: setMode(.plan)
        default: setMode(.default_)
        }
    }

    func setModel(_ alias: String) {
        session?.requestModelPicker = false
        let workspace = workspace, id = sessionID
        Task { await workspace.setModel(alias, for: id) }
    }
}
