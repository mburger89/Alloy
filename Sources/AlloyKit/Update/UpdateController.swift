import Foundation

/// What the controller needs from the updater engine. `SparkleDriver` is the real one; tests use a fake.
@MainActor
public protocol UpdateDriving: AnyObject {
    /// Persisted by the engine (Sparkle keeps it in the app's defaults).
    var automaticChecks: Bool { get set }
    /// When the engine last checked, kept across launches (Sparkle stores it in the app's defaults).
    var lastUpdateCheckDate: Date? { get }
    func start() throws
    func checkForUpdates()
    /// Applies the downloaded update now and relaunches. Only called after Alloy's shutdown has stopped every session.
    func installNow()
    /// Lets the downloaded update install as the app exits. Only called after the shutdown. The real engine does nothing
    /// here (Sparkle installs a prepared update at termination by itself); the call exists so tests can observe the rule.
    func installOnQuit()
}

/// Whether the updater may start: only in a real `.app` with a feed URL and a public key, never in tests or `swift run`.
public enum UpdateStartPolicy {
    public static func canStart(bundleURL: URL, info: [String: Any], environment: [String: String]) -> Bool {
        guard bundleURL.pathExtension == "app" else { return false }
        // A test runner is not a `.app` either; this also covers a bundled app launched under XCTest.
        if environment["XCTestConfigurationFilePath"] != nil || environment["XCTestBundlePath"] != nil { return false }
        guard let feed = info["SUFeedURL"] as? String, URL(string: feed)?.scheme?.hasPrefix("http") == true else { return false }
        // An EdDSA public key is 32 bytes in base64; a placeholder or a blank is no key.
        guard let key = info["SUPublicEDKey"] as? String,
              Data(base64Encoded: key.trimmingCharacters(in: .whitespacesAndNewlines))?.count == 32 else { return false }
        return true
    }
}

/// The test-feed override for the manual update test: `ALLOY_UPDATE_FEED_URL` replaces `SUFeedURL`, but only when the
/// bundle was not built for release. The bundler writes `AlloyReleaseBuild` into identity-signed builds; there the
/// variable is ignored, so a shipped app can never be pointed at another feed from its environment.
public enum UpdateFeedPolicy {
    public static func override(info: [String: Any], environment: [String: String]) -> String? {
        if info["AlloyReleaseBuild"] as? Bool == true { return nil }
        guard let raw = environment["ALLOY_UPDATE_FEED_URL"]?.trimmingCharacters(in: .whitespacesAndNewlines),
              let url = URL(string: raw), url.scheme == "https" || url.scheme == "http", url.host != nil else { return nil }
        return raw
    }
}

/// Maps the engine's callbacks onto `UpdateModel` and owns the install rules: an update is only installed on quit or
/// through Restart, and both run after `shutdown` (which stops every Claude session).
@MainActor
public final class UpdateController {
    public let model: UpdateModel
    private let driver: UpdateDriving
    private let shutdown: @MainActor () async -> Void
    private let now: @MainActor () -> Date
    private let hasBusySessions: @MainActor () -> Int
    public private(set) var started = false
    private var restarting = false

    public init(driver: UpdateDriving, model: UpdateModel, now: @escaping @MainActor () -> Date = { Date() },
                busySessions: @escaping @MainActor () -> Int = { 0 },
                shutdown: @escaping @MainActor () async -> Void = {}) {
        self.hasBusySessions = busySessions
        self.driver = driver
        self.model = model
        self.now = now
        self.shutdown = shutdown
        model.automaticChecks = driver.automaticChecks
        model.checkIntent = { [weak self] in self?.checkForUpdates() }
        model.restartIntent = { [weak self] in self?.restartToUpdate() }
        model.confirmRestartIntent = { [weak self] in self?.confirmRestart() }
        model.cancelRestartIntent = { [weak self] in self?.model.confirmingRestart = false }
        model.automaticChecksIntent = { [weak self] in self?.setAutomaticChecks($0) }
    }

    /// Starts the engine when the policy allows; otherwise nothing is started and false is returned.
    @discardableResult
    public func start(bundleURL: URL, info: [String: Any], environment: [String: String]) -> Bool {
        guard !started, UpdateStartPolicy.canStart(bundleURL: bundleURL, info: info, environment: environment) else { return false }
        do { try driver.start() } catch {
            failed(message: error.localizedDescription)
            return false
        }
        started = true
        model.automaticChecks = driver.automaticChecks
        // Settings must not say "Not checked yet" after a relaunch.
        if model.lastCheck == nil { model.lastCheck = driver.lastUpdateCheckDate }
        return true
    }

    public func checkForUpdates() {
        guard started else { return }
        // An update already waits: show it instead of starting a check Sparkle would refuse.
        if model.readyVersion != nil { showUpdateInFocus(); return }
        guard !model.isBusy else { return }
        driver.checkForUpdates()
    }

    public func setAutomaticChecks(_ on: Bool) {
        driver.automaticChecks = on
        model.automaticChecks = driver.automaticChecks
    }

    /// Brings the waiting update forward: its notes open over the chat (the banner is always in the sidebar).
    public func showUpdateInFocus() {
        if model.readyVersion != nil, model.notes != nil { model.showingNotes = true }
    }

    /// Banner action. With a busy session (working or awaiting permission) the banner first asks; otherwise this
    /// shuts down as for a quit (sessions stop), then installs and relaunches.
    public func restartToUpdate() {
        guard started, model.readyVersion != nil, !restarting else { return }
        let busy = hasBusySessions()
        if busy > 0 {
            model.busySessionCount = busy
            model.confirmingRestart = true
            return
        }
        beginRestart()
    }

    /// The banner's "Restart anyway".
    public func confirmRestart() {
        guard model.confirmingRestart else { return }
        model.confirmingRestart = false
        guard started, model.readyVersion != nil, !restarting else { return }
        beginRestart()
    }

    private func beginRestart() {
        restarting = true
        Task { @MainActor in
            await shutdown()
            driver.installNow()
        }
    }

    /// Called by the quit path once the shutdown finished: a waiting update installs as the app exits.
    public func applicationWillQuit() {
        guard started, !restarting, model.readyVersion != nil else { return }
        driver.installOnQuit()
    }

    // MARK: Events from the engine

    public func checkStarted() {
        guard !holdsReady else { return }
        model.state = .checking
    }

    public func updateFound(version: String, notes: String?) {
        if let notes { model.notes = notes }
        guard !holdsReady else { return }
        model.state = .available(version: version, notes: model.notes)
    }

    public func notesArrived(_ notes: String) { model.notes = notes }

    public func downloadProgress(_ progress: Double?) {
        guard !holdsReady else { return }
        model.state = .downloading(progress: progress)
    }

    public func readyToInstall(version: String, notes: String? = nil) {
        if let notes { model.notes = notes }
        model.state = .readyToInstall(version: version)
    }

    /// No update: quiet. A waiting update stays waiting.
    public func noUpdate() {
        model.lastCheck = now()
        model.lastFailure = nil
        // Only a check in flight or a shown error ends here; an offered (information-only) update stays offered.
        switch model.state {
        case .checking, .error: model.state = .idle
        default: break
        }
    }

    /// A failed check or download: no modal. Settings shows "Couldn't check for updates" with the time.
    public func failed(message: String) {
        model.lastCheck = now()
        model.lastFailure = now()
        if !holdsReady { model.state = .error(message: message) }
    }

    /// The engine's session ended; a state left mid-way (checking, downloading) goes back to idle.
    public func sessionEnded() {
        if model.isBusy { model.state = .idle }
    }

    /// An update cycle finished (scheduled checks included, which never reach the user driver). `errorMessage` is nil
    /// for a good cycle, "no update" included. Quiet either way.
    public func cycleFinished(errorMessage: String?) {
        if let errorMessage { failed(message: errorMessage) } else { noUpdate() }
        sessionEnded()
    }

    /// The termination Restart asked for did not happen (cancelled, or still waiting): Restart works again.
    public func restartAborted() {
        restarting = false
    }

    /// Sparkle dropped the prepared update (installer error, aborted session): the banner goes and Restart works again.
    public func preparedUpdateDropped() {
        restarting = false
        model.confirmingRestart = false
        if holdsReady { model.state = .idle }
        sessionEnded()
    }

    private var holdsReady: Bool { model.readyVersion != nil }
}
