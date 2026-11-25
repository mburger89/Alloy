import Foundation
import Sparkle

/// The real engine: Sparkle's `SPUUpdater` with this class as its user driver, so no Sparkle window ever opens.
/// Updates download in the background; nothing installs until `installNow` (after Alloy's shutdown) or the app quits.
@MainActor
public final class SparkleDriver: NSObject, UpdateDriving, SPUUserDriver {
    public weak var controller: UpdateController?
    private var updater: SPUUpdater?
    // swiftlint:disable:next weak_delegate - this driver is the delegate's only owner; SPUUpdater holds it weakly, so weak here would free it at once
    private let delegate = SparkleDelegate()
    private let defaults: UserDefaults

    /// Release notes and the version of the update in play, kept for the ready-to-install step.
    private var pendingVersion = ""
    private var pendingNotes: String?
    private var expectedLength: UInt64 = 0
    private var receivedLength: UInt64 = 0
    /// Manual path: Sparkle waits for the answer to "install and relaunch?".
    private var readyReply: ((SPUUserUpdateChoice) -> Void)?
    /// Automatic path: Sparkle installs on quit by itself; this block installs right now.
    private var immediateInstall: (@Sendable () -> Void)?
    /// Sparkle's offer to ask the app to terminate again, after a first request did not end the app.
    private var retryTermination: (() -> Void)?

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        super.init()
        delegate.onWillInstallOnQuit = { [weak self] version, notes, block in
            MainActor.assumeIsolated { self?.willInstallOnQuit(version: version, notes: notes, block: block) }
        }
        delegate.onCycleFinished = { [weak self] message in
            MainActor.assumeIsolated { self?.automaticSessionEnded(); self?.controller?.cycleFinished(errorMessage: message) }
        }
    }

    public var automaticChecks: Bool {
        get { updater?.automaticallyChecksForUpdates ?? (defaults.object(forKey: "SUEnableAutomaticChecks") as? Bool ?? true) }
        set {
            if let updater { updater.automaticallyChecksForUpdates = newValue } else { defaults.set(newValue, forKey: "SUEnableAutomaticChecks") }
        }
    }

    public func start() throws {
        let updater = SPUUpdater(hostBundle: .main, applicationBundle: .main, userDriver: self, delegate: delegate)
        // Updates are fetched in the background so they are ready to install on quit.
        updater.automaticallyDownloadsUpdates = true
        updater.sendsSystemProfile = false
        try updater.start()
        self.updater = updater
    }

    public var lastUpdateCheckDate: Date? { updater?.lastUpdateCheckDate }

    /// The test-feed override (see `UpdateFeedPolicy`); nil in release builds and when unset.
    public var feedURLOverride: String? {
        get { delegate.feedURLOverride }
        set { delegate.feedURLOverride = newValue }
    }

    public func checkForUpdates() { updater?.checkForUpdates() }

    /// Live paths first: a held reply (manual session), then a retry of the termination Sparkle already asked for,
    /// then the automatic session's block (kept for reuse; Sparkle allows calling it again).
    public func installNow() {
        if let readyReply { self.readyReply = nil; readyReply(.install) }
        else if let retryTermination { retryTermination() }
        else if let immediateInstall { immediateInstall() }
    }

    func holdReadyReply(_ reply: @escaping (SPUUserUpdateChoice) -> Void) {
        readyReply = reply
        immediateInstall = nil   // a newer session supersedes the automatic one
        retryTermination = nil
    }

    func holdImmediateInstall(_ block: @escaping @Sendable () -> Void) {
        immediateInstall = block
    }

    /// The automatic session ended without installing (it aborted): its block is dead and nothing is left to install
    /// unless a manual session holds a reply.
    func automaticSessionEnded() {
        guard immediateInstall != nil else { return }
        immediateInstall = nil
        if readyReply == nil { controller?.preparedUpdateDropped() }
    }

    /// Nothing to do: Sparkle installs a prepared update when the app terminates (held reply or not), and answering
    /// "dismiss" here would end its session while the installer stays, which a window close (the app keeps running)
    /// would turn into a surprise relaunch on the next check.
    public func installOnQuit() {}

    private func willInstallOnQuit(version: String, notes: String?, block: @escaping @Sendable () -> Void) {
        holdImmediateInstall(block)
        controller?.readyToInstall(version: version, notes: notes)
    }

    // MARK: SPUUserDriver

    public func show(_ request: SPUUpdatePermissionRequest,
                                            reply: @escaping (SUUpdatePermissionResponse) -> Void) {
        reply(SUUpdatePermissionResponse(automaticUpdateChecks: automaticChecks, sendSystemProfile: false))
    }

    public func showUserInitiatedUpdateCheck(cancellation: @escaping () -> Void) { controller?.checkStarted() }

    public func showUpdateFound(with appcastItem: SUAppcastItem, state: SPUUserUpdateState,
                                reply: @escaping (SPUUserUpdateChoice) -> Void) {
        pendingVersion = appcastItem.displayVersionString
        pendingNotes = ReleaseNotesFormat.text(appcastItem.itemDescription, format: appcastItem.itemDescriptionFormat)
        switch UpdateFoundDecision.decide(stage: state.stage, informationOnly: appcastItem.isInformationOnlyUpdate) {
        case .download:
            controller?.updateFound(version: pendingVersion, notes: pendingNotes)
            reply(.install)   // fetch now; the install itself waits for quit or Restart
        case .holdAsReady:
            // A prepared installer resumed: answering "install" would quit and relaunch at once. Hold it like any ready update.
            holdReadyReply(reply)
            controller?.readyToInstall(version: pendingVersion, notes: pendingNotes)
        case .dismiss:
            controller?.updateFound(version: pendingVersion, notes: pendingNotes)
            reply(.dismiss)
        }
    }

    public func showUpdateReleaseNotes(with downloadData: SPUDownloadData) {
        guard let raw = String(data: downloadData.data, encoding: .utf8),
              let text = ReleaseNotesFormat.text(raw, format: ReleaseNotesFormat.format(forMIMEType: downloadData.mimeType)) else { return }
        pendingNotes = text
        controller?.notesArrived(text)
    }

    public func showUpdateReleaseNotesFailedToDownloadWithError(_ error: any Error) {}

    public func showUpdateNotFoundWithError(_ error: any Error, acknowledgement: @escaping () -> Void) {
        controller?.noUpdate()
        acknowledgement()
    }

    public func showUpdaterError(_ error: any Error, acknowledgement: @escaping () -> Void) {
        controller?.failed(message: error.localizedDescription)
        acknowledgement()
    }

    public func showDownloadInitiated(cancellation: @escaping () -> Void) {
        expectedLength = 0
        receivedLength = 0
        controller?.downloadProgress(nil)
    }

    public func showDownloadDidReceiveExpectedContentLength(_ expectedContentLength: UInt64) { expectedLength = expectedContentLength }

    public func showDownloadDidReceiveData(ofLength length: UInt64) {
        receivedLength += length
        controller?.downloadProgress(expectedLength > 0 ? min(1, Double(receivedLength) / Double(expectedLength)) : nil)
    }

    public func showDownloadDidStartExtractingUpdate() { controller?.downloadProgress(1) }

    public func showExtractionReceivedProgress(_ progress: Double) {}

    public func showReady(toInstallAndRelaunch reply: @escaping (SPUUserUpdateChoice) -> Void) {
        holdReadyReply(reply)
        controller?.readyToInstall(version: pendingVersion, notes: pendingNotes)
    }

    public func showInstallingUpdate(withApplicationTerminated applicationTerminated: Bool,
                                     retryTerminatingApplication: @escaping () -> Void) {
        retryTermination = retryTerminatingApplication
        // The app has not terminated (cancelled, or still waiting): Restart must work again, and retry re-asks.
        if !applicationTerminated { controller?.restartAborted() }
    }

    public func showUpdateInstalledAndRelaunched(_ relaunched: Bool, acknowledgement: @escaping () -> Void) { acknowledgement() }

    public func dismissUpdateInstallation() {
        let heldUpdate = readyReply != nil || immediateInstall != nil || retryTermination != nil
        readyReply = nil
        immediateInstall = nil
        retryTermination = nil
        if heldUpdate { controller?.preparedUpdateDropped() } else { controller?.sessionEnded() }
    }

    public func showUpdateInFocus() { controller?.showUpdateInFocus() }
}

/// Sparkle's updater delegate, kept apart because its methods are not main-actor isolated in the SDK.
final class SparkleDelegate: NSObject, SPUUpdaterDelegate, @unchecked Sendable {
    var onWillInstallOnQuit: (@Sendable (String, String?, @escaping @Sendable () -> Void) -> Void)?
    var onCycleFinished: (@Sendable (String?) -> Void)?
    var feedURLOverride: String?

    func feedURLString(for updater: SPUUpdater) -> String? { feedURLOverride }

    func updater(_ updater: SPUUpdater, willInstallUpdateOnQuit item: SUAppcastItem,
                 immediateInstallationBlock immediateInstallHandler: @escaping () -> Void) -> Bool {
        nonisolated(unsafe) let block = immediateInstallHandler
        onWillInstallOnQuit?(item.displayVersionString, ReleaseNotesFormat.text(item.itemDescription, format: item.itemDescriptionFormat)) { block() }
        return true
    }

    func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: (any Error)?) {
        onCycleFinished?(UpdateCycleError.message(error))
    }
}

/// What to do with a found update, from where Sparkle's session stands. Pure, so every stage is tested
/// (`SPUUserUpdateState` cannot be built outside Sparkle).
enum UpdateFoundDecision: Equatable {
    /// Answer "install", which only downloads here.
    case download
    /// The installer is already prepared (`.installing`): answering "install" would relaunch now. Keep the reply.
    case holdAsReady
    case dismiss

    static func decide(stage: SPUUserUpdateStage, informationOnly: Bool) -> UpdateFoundDecision {
        if informationOnly { return .dismiss }
        switch stage {
        case .installing: return .holdAsReady
        case .notDownloaded, .downloaded: return .download
        @unknown default: return .dismiss
        }
    }
}

enum UpdateCycleError {
    /// nil for no error and for "no update"; the description for a real failure.
    static func message(_ error: (any Error)?) -> String? {
        guard let error else { return nil }
        let ns = error as NSError
        if ns.domain == SUSparkleErrorDomain, ns.code == Int(SUError.noUpdateError.rawValue) { return nil }
        return ns.localizedDescription
    }
}
