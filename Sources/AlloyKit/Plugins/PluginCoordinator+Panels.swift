import AlloyCore
import AlloyPlugins
import Foundation

/// Plugin panels in the Code sidebar: tabs for the enabled plugins' manifest panels, a model per panel holding the plugin's
/// latest tree, and the events a visible panel sends back. A panel whose tab is not selected has no element and no task.
extension PluginCoordinator {
    /// Installs the hook that follows the sidebar's selection (called when a workspace is bound).
    func installPanelSelection(on workspace: Workspace) {
        workspace.codeLayout.onPluginPanelChange = { [weak self] old, new in self?.panelSelectionChanged(old, new) }
    }

    /// The tabs of every effectively enabled scripted plugin's panels, in plugin-id order.
    func applyPanels(_ specs: [(pluginID: String, panels: [PluginPanelSpec])]) {
        panels.setTabs(specs.flatMap { entry in entry.panels.map { PluginPanelTab(pluginID: entry.pluginID, panelID: $0.id, title: $0.title) } })
        if let selected = workspace?.codeLayout.pluginPanel, !panels.tabs.contains(where: { $0.key == selected }) {
            workspace?.codeLayout.pluginPanel = nil
        }
    }

    func panelSender(_ pluginID: String, _ panelID: String) -> PluginPanelSender {
        PluginPanelSender(token: "\(pluginID)/\(panelID)") { [weak self] key, kind, value in
            self?.sendPanelEvent(pluginID: pluginID, panelID: panelID, key: key, kind: kind, value: value)
        }
    }

    private func sendPanelEvent(pluginID: String, panelID: String, key: String, kind: String, value: JSONValue?) {
        guard isActive(pluginID) else { return }
        var params: [String: JSONValue] = ["panelId": .string(panelID), "key": .string(key), "kind": .string(kind)]
        if let value { params["value"] = value }
        notifyPlugin(pluginID, "panel/event", .object(params))
    }

    private static func split(_ selection: String) -> (plugin: String, panel: String)? {
        guard let slash = selection.lastIndex(of: "/") else { return nil }
        return (String(selection[..<slash]), String(selection[selection.index(after: slash)...]))
    }

    /// A tab was selected or left: the plugin starts and hears `panel/opened`, or hears `panel/closed`; an open panel keeps its
    /// plugin from idling out.
    private func panelSelectionChanged(_ old: String?, _ new: String?) {
        if let old, let (plugin, panel) = Self.split(old) {
            notifyPlugin(plugin, "panel/closed", .object(["panelId": .string(panel)]))
            setPanelOpen(plugin, false)
        }
        if let new, let (plugin, panel) = Self.split(new), isActive(plugin) {
            setPanelOpen(plugin, true)
            activateAsync(plugin, .panel)
            notifyPlugin(plugin, "panel/opened", .object(["panelId": .string(panel)]))
        }
    }

    /// Events the host emitted for panels. True when `event` was one.
    func handlePanelEvent(_ event: PluginHostEvent) -> Bool {
        switch event {
        case .panel(let id, let panelID, let tree):
            guard isActive(id), panels.tabs.contains(where: { $0.pluginID == id && $0.panelID == panelID }) else { return true }
            let model = panels.model(id, panelID)
            if model.tree != tree { model.tree = tree }
            return true
        case .panelRejected(let id, let panelID, let reason):
            guard isActive(id) else { return true }
            appendLog(plugin: id, "Panel \(panelID): \(reason)")
            return true
        default:
            return false
        }
    }

    /// The plugin's process state reached its panels: while it is down they say so; when it is back, the visible one hears
    /// `panel/opened` again so the new process renders it.
    func panelStateChanged(_ id: String, _ state: PluginRunState) {
        let down: Bool
        switch state {
        case .running, .starting, .notStarted: down = false
        default: down = true
        }
        if down { panelWasDown.insert(id) }
        for model in panels.models(of: id) where model.stopped != down { model.stopped = down }
    }

    func panelPluginStarted(_ id: String) {
        guard let selected = workspace?.codeLayout.pluginPanel, let (plugin, panel) = Self.split(selected), plugin == id,
              panelWasDown.remove(id) != nil else { return }
        notifyPlugin(id, "panel/opened", .object(["panelId": .string(panel)]))
    }
}
