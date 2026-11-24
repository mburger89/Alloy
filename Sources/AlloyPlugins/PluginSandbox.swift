import Foundation

/// Whether scripted plugins that need `network` or `process.spawn` can be confined on this platform.
public enum PluginSandbox {
    /// No sandbox backend exists yet, so no scripted plugin with `network` or `process.spawn` can be enabled.
    public static var backendAvailable: Bool { false }
}
