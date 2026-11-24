import AlloyCore
import AlloyPlugins
import Foundation
import Observation

public enum PluginRowStatus: Equatable {
    case disabled, notStarted, running, stopped
    /// A declarative plugin that is switched on (nothing of it runs as a process).
    case enabled
    /// A folder in the plugin directory with no settings entry.
    case notEnabled
    /// A scripted plugin while Alloy cannot run scripted plugins yet.
    case scriptedUnavailable
    case crashed(Int)
    case disabledAfterCrashes
    case needsAPI(Int)
    case sandboxUnavailable
    case failedToStart(String)
    case badManifest(String)
    case missing
    case needsPermissions([PluginPermission])

    public var text: String {
        switch self {
        case .disabled: "disabled"
        case .notStarted: "not started"
        case .running: "running"
        case .enabled: "enabled"
        case .notEnabled: "not enabled"
        case .scriptedUnavailable: "Scripted plugins arrive in a later Alloy version"
        case .stopped: "stopped"
        case .crashed(let n): n == 1 ? "crashed once" : "crashed \(n) times"
        case .disabledAfterCrashes: "disabled after crashes"
        case .needsAPI(let v): "needs API v\(v)"
        case .sandboxUnavailable: "sandbox unavailable"
        case .failedToStart(let why): "could not start: \(why)"
        case .badManifest(let why): "bad manifest: \(why)"
        case .missing: "folder missing"
        case .needsPermissions: "needs new permissions"
        }
    }
}

/// One installed plugin as Settings › Plugins shows it.
public struct PluginRowState: Equatable {
    public var id: String
    public var name: String
    public var version: String
    public var source: PluginSource?
    public var enabled: Bool
    public var permissions: [PluginPermission]
    public var status: PluginRowStatus
    public var notes: [String]
    public var settings: [PluginSettingSpec]
    public var isScripted: Bool
    /// The exact commands Alloy would launch for this plugin (servers and tasks), listed in the enable prompt.
    public var commandsToRun: [String]
}

/// What the Plugins settings section reads. Only that section observes it; the coordinator writes it when a row changes.
@MainActor @Observable
public final class PluginStatusModel {
    public internal(set) var rows: [PluginRowState] = []

    public init() {}

    func update(_ next: [PluginRowState]) {
        if rows != next { rows = next }
    }
}
