import AlloyCore
import MetalUI
import Observation

/// The window's root before and after a project is chosen: a chooser until `workspace` is set, then the app.
@MainActor @Observable
public final class LauncherModel {
    public private(set) var workspace: Workspace?
    /// Why the last folder was refused; shown in an alert.
    public var message: String?
    /// Presents the open-folder panel (set by the entry point).
    public var chooseFolder: (@MainActor () -> Void)?
    /// Runs when a shutdown has stopped every session, just before the quit or close is allowed.
    public var onShutdownComplete: (@MainActor () -> Void)?

    public init(workspace: Workspace? = nil) { self.workspace = workspace }

    public func adopt(_ workspace: Workspace) { self.workspace = workspace }

    /// Whether a shutdown (window close or quit) is already running.
    private var shuttingDown = false
    /// Every close or quit reply waiting on the running shutdown; all are called when it finishes.
    private var pendingReplies: [@MainActor (Bool) -> Void] = []

    /// Answers a close or quit request. With sessions to stop it replies `.later`, awaits
    /// `workspace.saveAll()` (unsaved typing reaches disk) and then `workspace.stopAll()` (every `claude` exits first), then calls `reply(true)`.
    public func shutdownRequested(reply: @escaping @MainActor (Bool) -> Void) -> CloseRequestReply {
        guard let workspace else { return .now }
        pendingReplies.append(reply)
        guard !shuttingDown else { return .later }
        // One alert covers every request that arrives while it is open.
        guard quitPrompt == nil, !askingAboutUntitled else { return .later }
        // Untitled tabs with text ask first (Save… / Don't Save / Cancel), in tab order; a Cancel stops the quit.
        let untitled = workspace.untitledKeysWithText()
        if !untitled.isEmpty {
            askingAboutUntitled = true
            Task { @MainActor [weak self] in
                for key in untitled {
                    guard await workspace.resolveUntitled(key) else {
                        self?.askingAboutUntitled = false
                        self?.refuseWaitingRequests()
                        return
                    }
                }
                self?.askingAboutUntitled = false
                self?.continueShutdown(workspace)
            }
            return .later
        }
        continueShutdown(workspace)
        return .later
    }

    /// True while the Untitled tabs are being asked about, so a second request waits on the same answers.
    private var askingAboutUntitled = false

    /// The busy-terminal check, then the shutdown itself.
    private func continueShutdown(_ workspace: Workspace) {
        let busy = workspace.busyTerminalCount?() ?? 0
        if busy > 0 {
            quitPrompt = busy == 1
                ? "1 terminal is running a process. Quit anyway?"
                : "\(busy) terminals are running a process. Quit anyway?"
            return
        }
        beginShutdown(workspace)
    }

    /// Replies `false` to every waiting close or quit request.
    private func refuseWaitingRequests() {
        let replies = pendingReplies
        pendingReplies = []
        for r in replies { r(false) }
    }

    /// Non-nil while the busy-terminal alert is showing; its text is the alert message.
    public private(set) var quitPrompt: String?

    /// The alert's answer. Quit runs the normal shutdown; Cancel refuses every waiting request and does nothing else.
    public func answerQuitPrompt(_ quit: Bool) {
        guard quitPrompt != nil else { return }
        quitPrompt = nil
        if quit, let workspace {
            beginShutdown(workspace)
        } else {
            refuseWaitingRequests()
        }
    }

    private func beginShutdown(_ workspace: Workspace) {
        shuttingDown = true
        Task { @MainActor [weak self] in
            await workspace.saveAll()
            await workspace.stopAll()
            // A tool result that arrived while the sessions stopped may have changed an open file.
            await workspace.settle()
            await workspace.saveAll()
            // Let the ledger write for those saves finish before the app is told it may quit.
            await workspace.settle()
            guard let self else { return }
            // Every session has stopped: a waiting update may now install as the app exits.
            onShutdownComplete?()
            let replies = pendingReplies
            pendingReplies = []
            shuttingDown = false
            for r in replies { r(true) }
        }
    }
}

/// Closing the window stops every session before the window goes. The Settings window goes first, so the app, with
/// no window left, quits.
@MainActor
public func installWindowShutdown(on window: Window, model: LauncherModel, settings: SettingsWindowController? = nil) {
    window.onCloseRequest = { [weak window] in
        model.shutdownRequested {
            if $0 { settings?.close() }
            window?.replyToCloseRequest($0)
        }
    }
}

@MainActor
public func launcherRoot(model: LauncherModel, themes: ThemeController? = nil, updates: UpdateModel? = nil,
                         center: CommandCenter) -> some Element {
    VStack(spacing: 0) {
        if let workspace = model.workspace {
            AlloyScreen(workspace: workspace, themes: themes, updates: updates, center: center)
        } else {
            ChooseProjectView(model: model, updates: updates)
        }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background { WindowBackdropView(style: themes?.style ?? .defaults).equatable() }
    .alert("Quit Alloy?", isPresented: Binding(get: { model.quitPrompt != nil }, set: { if !$0 { model.answerQuitPrompt(false) } })) {
        Button("Quit") { model.answerQuitPrompt(true) }
            .accessibilityIdentifier("quit-terminal-confirm")
        Button("Cancel") { model.answerQuitPrompt(false) }
            .accessibilityIdentifier("quit-terminal-cancel")
    } message: {
        Text(verbatim: model.quitPrompt ?? "")
    }
    .alert(UntitledPrompt.question(for: model.workspace?.untitledPrompt?.title ?? ""),
           isPresented: Binding(get: { model.workspace?.untitledPrompt != nil },
                                set: { if !$0 { model.workspace?.untitledPrompt?.answer(.cancel) } })) {
        Button("Save\u{2026}") { model.workspace?.untitledPrompt?.answer(.save) }
            .accessibilityIdentifier("untitled-save")
        Button("Don't Save") { model.workspace?.untitledPrompt?.answer(.discard) }
            .accessibilityIdentifier("untitled-discard")
        Button("Cancel", role: .cancel) { model.workspace?.untitledPrompt?.answer(.cancel) }
            .accessibilityIdentifier("untitled-cancel")
    } message: {
        Text(verbatim: UntitledPrompt.message)
    }
}

struct ChooseProjectView: Component {
    let model: LauncherModel
    /// A waiting update shows here too (its banner and release notes), so it is not hidden until a project opens.
    var updates: UpdateModel?

    var content: some ElementGroup {
        let model = model
        ZStack {
            VStack(spacing: 0) {
                if let updates {
                    UpdateBanner(model: updates).equatable()
                }
                chooser(model)
            }
            if let updates { UpdateNotesOverlay(model: updates) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ElementBuilder
    private func chooser(_ model: LauncherModel) -> some ElementGroup {
        VStack(spacing: Pixels(12)) {
            Text("Choose a project folder to open in Alloy.").font(size: 14)
            Button("Choose folder…") { model.chooseFolder?() }
                .accessibilityIdentifier("choose-folder")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .alert("Alloy can't use that folder", isPresented: Binding(get: { model.message != nil }, set: { if !$0 { model.message = nil } })) {
            Button("Choose another folder…") { model.chooseFolder?() }
        } message: {
            Text(verbatim: model.message ?? "")
        }
    }
}
