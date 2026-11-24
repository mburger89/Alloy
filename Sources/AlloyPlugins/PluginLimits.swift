import Foundation

/// Every budget the plugin host enforces. Tests shrink them; nothing in the app raises them.
public struct PluginLimits: Sendable {
    public var maxRunning = 8
    public var idleStop: Double = 600
    public var backoff: [Double] = [1, 5, 30]
    public var crashWindow: Double = 600
    public var crashesToDisable = 3
    public var uiTimeout: Duration = .seconds(2)
    public var requestTimeout: Duration = .seconds(10)
    public var timeoutsToRestart = 3
    public var messagesPerSecond = 200
    public var chattySecondsToRestart = 5
    public var chattyWindow: Double = 60
    public var writeQueueBytes = 1 << 20
    public var sampleInterval: Double = 5
    public var residentLimit: UInt64 = 500 << 20
    public var cpuLimit = 0.9
    public var cpuWindow: Double = 30
    public var stopGrace: Duration = .seconds(2)
    public var maxStartup = 3
    public var decorationHop = 0.25
    public var maxDecorations = 500
    public var toastInterval: Double = 5
    public var maxPanelElements = 300
    public var stateBytes = 64 << 10
    public var stateDebounce: Double = 1
    public var textFieldDebounce = 0.3

    public init() {}
}
