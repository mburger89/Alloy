import Foundation
import Observation

/// Where the updater is. Only `readyToInstall` shows the sidebar banner; every other state is quiet.
public enum UpdateState: Equatable, Sendable {
    case idle
    case checking
    case available(version: String, notes: String?)
    /// `progress` is 0...1, or nil while the size is not known yet.
    case downloading(progress: Double?)
    case readyToInstall(version: String)
    case error(message: String)
}

/// What the update UI reads: the state, the release notes, the last check and the automatic-checks flag. The views
/// observe only this object. The controller writes it; the UI asks through the three intents, which the controller sets.
@MainActor @Observable
public final class UpdateModel {
    public internal(set) var state: UpdateState = .idle
    /// Release notes (Markdown) of the update being offered or waiting to install.
    public internal(set) var notes: String?
    public internal(set) var lastCheck: Date?
    /// When the last check failed, if it did; cleared by the next good check.
    public internal(set) var lastFailure: Date?
    public internal(set) var automaticChecks = true
    /// The release notes panel is open.
    public var showingNotes = false
    /// Restart was asked while a session is busy: the banner asks before stopping it.
    public internal(set) var confirmingRestart = false
    /// How many sessions the confirmation names.
    public internal(set) var busySessionCount = 0

    @ObservationIgnored var checkIntent: (@MainActor () -> Void)?
    @ObservationIgnored var restartIntent: (@MainActor () -> Void)?
    @ObservationIgnored var confirmRestartIntent: (@MainActor () -> Void)?
    @ObservationIgnored var cancelRestartIntent: (@MainActor () -> Void)?
    @ObservationIgnored var automaticChecksIntent: (@MainActor (Bool) -> Void)?

    public init() {}

    public var isBusy: Bool {
        switch state {
        case .checking, .downloading: true
        default: false
        }
    }

    /// The version waiting to install, if one is.
    public var readyVersion: String? {
        if case .readyToInstall(let version) = state { return version }
        return nil
    }

    public func checkForUpdates() { checkIntent?() }
    public func restartToUpdate() { restartIntent?() }
    public func confirmRestart() { confirmRestartIntent?() }
    public func cancelRestart() { cancelRestartIntent?() }
    public func setAutomaticChecks(_ on: Bool) { automaticChecksIntent?(on) }
}
