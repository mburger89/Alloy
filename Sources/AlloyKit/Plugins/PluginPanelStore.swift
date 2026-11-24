import AlloyCore
import AlloyPlugins
import Foundation

/// A plugin panel's tab in the Code sidebar.
struct PluginPanelTab: Equatable, Sendable {
    let pluginID: String
    let panelID: String
    let title: String
    /// The value of `CodeLayout.pluginPanel` that selects this tab.
    var key: String { "\(pluginID)/\(panelID)" }
}

/// The panel tabs of the enabled plugins and the per-panel models. Only the Code sidebar reads `tabs`.
@MainActor @Observable
final class PluginPanelStore {
    private(set) var tabs: [PluginPanelTab] = []
    @ObservationIgnored private var models: [String: PluginPanelModel] = [:]
    @ObservationIgnored let debounce: Double

    init(debounce: Double = 0.3) { self.debounce = debounce }

    /// Replaces the tabs; an unchanged list assigns nothing. Models of panels that went away are dropped.
    func setTabs(_ next: [PluginPanelTab]) {
        guard next != tabs else { return }
        tabs = next
        let live = Set(next.map(\.key))
        for key in models.keys where !live.contains(key) { models[key]?.cancelTyping(); models[key] = nil }
    }

    func model(_ pluginID: String, _ panelID: String) -> PluginPanelModel {
        let key = "\(pluginID)/\(panelID)"
        if let existing = models[key] { return existing }
        let model = PluginPanelModel(pluginID: pluginID, panelID: panelID, debounce: debounce)
        models[key] = model
        return model
    }

    func existingModel(_ pluginID: String, _ panelID: String) -> PluginPanelModel? { models["\(pluginID)/\(panelID)"] }

    func models(of pluginID: String) -> [PluginPanelModel] { models.values.filter { $0.pluginID == pluginID } }
}

/// What one panel shows: the plugin's latest tree and whether its process is down.
@MainActor @Observable
final class PluginPanelModel {
    let pluginID: String
    let panelID: String
    var tree: PluginPanelTree?
    var stopped = false
    @ObservationIgnored private let debounce: Double
    @ObservationIgnored private var typing: [String: (text: String, task: Task<Void, Never>)] = [:]

    init(pluginID: String, panelID: String, debounce: Double) {
        self.pluginID = pluginID
        self.panelID = panelID
        self.debounce = debounce
    }

    /// A text field changed: the plugin hears `changed` once, `debounce` seconds after the last edit.
    func typed(key: String, text: String, send: PluginPanelSender) {
        typing[key]?.task.cancel()
        let delay = debounce
        let task = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .seconds(delay)) } catch { return }
            self?.typing[key] = nil
            send(key, "changed", .string(text))
        }
        typing[key] = (text, task)
    }

    /// Return in a text field: a pending `changed` goes first, then `submit`.
    func submitted(key: String, text: String, send: PluginPanelSender) {
        if let pending = typing.removeValue(forKey: key) {
            pending.task.cancel()
            send(key, "changed", .string(pending.text))
        }
        send(key, "submit", .string(text))
    }

    func cancelTyping() {
        for entry in typing.values { entry.task.cancel() }
        typing = [:]
    }
}

/// How a panel's widgets talk to the plugin: `(key, kind, value)`.
struct PluginPanelSender: Equatable {
    let token: String
    let handler: @MainActor (String, String, JSONValue?) -> Void

    static func == (a: Self, b: Self) -> Bool { a.token == b.token }

    @MainActor func callAsFunction(_ key: String, _ kind: String, _ value: JSONValue? = nil) { handler(key, kind, value) }
}
