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
            let replies = pendingReplies
            pendingReplies = []
            shuttingDown = false
            for r in replies { r(true) }
        }
        return .later
    }
}

/// Closing the window stops every session before the window goes.
@MainActor
public func installWindowShutdown(on window: Window, model: LauncherModel) {
    window.onCloseRequest = { [unowned window] in
        model.shutdownRequested { window.replyToCloseRequest($0) }
    }
}

@MainActor
public func launcherRoot(model: LauncherModel) -> some Element {
    VStack(spacing: 0) {
        if let workspace = model.workspace {
            AlloyScreen(workspace: workspace)
        } else {
            ChooseProjectView(model: model)
        }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(.chatFill)
}

struct ChooseProjectView: Component {
    let model: LauncherModel

    var content: some ElementGroup {
        let model = model
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
