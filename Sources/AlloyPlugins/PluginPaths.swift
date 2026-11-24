import Foundation

/// Where plugins live on disk, under Alloy's application-support folder.
public struct PluginPaths: Sendable {
    public let appSupport: URL

    public init(appSupport: URL) { self.appSupport = appSupport }

    /// Installed plugin folders, one per plugin id.
    public var plugins: URL { appSupport.appendingPathComponent("Alloy/Plugins") }
    /// Pid files of running plugin process groups.
    public var running: URL { plugins.appendingPathComponent(".running") }
    /// Installs are assembled here and moved into place.
    public var staging: URL { plugins.appendingPathComponent(".staging") }
    /// Per-plugin data (state, scratch).
    public var data: URL { appSupport.appendingPathComponent("Alloy/PluginData") }

    /// The plugin's scratch folder, handed to it as `TMPDIR`.
    public func scratch(_ id: String) -> URL { data.appendingPathComponent(id).appendingPathComponent("tmp") }
}
