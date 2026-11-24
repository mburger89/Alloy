import AlloyCore
import AlloyPlugins
import MetalUI

/// One plugin panel in the Code sidebar: the plugin's latest tree under an optional "Plugin stopped" line. Reads only its
/// model, so editor typing never re-runs it.
struct PluginPanelView: Component, Equatable {
    let model: PluginPanelModel
    let send: PluginPanelSender

    nonisolated static func == (a: Self, b: Self) -> Bool { a.model === b.model && a.send == b.send }

    var content: some ElementGroup {
        let _ = BodyProbe.hit("PluginPanelView")
        let model = model, send = send
        let prefix = "plugin.panel.\(model.pluginID)"
        VStack(alignment: .leading, spacing: Pixels(6)) {
            if model.stopped {
                Text(verbatim: "Plugin stopped").font(size: 11).foregroundColor(.warningInk)
                    .accessibilityIdentifier("\(prefix).\(model.panelID).stopped")
            }
            if let tree = model.tree {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        PluginPanelNodeView(node: tree.root, model: model, send: send).equatable()
                    }
                    .padding(inset(8, 6))
                }
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("\(prefix).\(model.panelID)")
    }
}

/// One node of a panel. Children are keyed by the plugin's `key`, so a re-render keeps focus and scroll.
struct PluginPanelNodeView: Component, Equatable {
    let node: PluginPanelNode
    let model: PluginPanelModel
    let send: PluginPanelSender

    nonisolated static func == (a: Self, b: Self) -> Bool { a.node == b.node && a.model === b.model && a.send == b.send }

    var content: some ElementGroup {
        let _ = BodyProbe.hit("PluginPanelNodeView")
        let model = model, send = send
        let id = "plugin.panel.\(model.pluginID).\(node.key)"
        switch node {
        case .text(_, let text, let role):
            Text(verbatim: text).font(size: 12).foregroundColor(role?.ink ?? Color.primary).accessibilityIdentifier(id)
        case .button(let key, let title):
            Button(action: { send(key, "click") }) { Text(verbatim: title).font(size: 12) }
                .accessibilityIdentifier(id)
        case .toggle(let key, let title, let isOn):
            Toggle(isOn: Binding(get: { isOn }, set: { send(key, "changed", .bool($0)) })) { Text(verbatim: title).font(size: 12) }
                .accessibilityIdentifier(id)
        case .textField(let key, let placeholder, let text):
            PluginPanelTextField(model: model, send: send, key: key, placeholder: placeholder, text: text, identifier: id).equatable()
        case .picker(let key, let title, let options, let selection):
            Picker(title, selection: Binding(get: { selection }, set: { send(key, "changed", .string($0)) })) {
                ForEach(options, id: \.value) { Text(verbatim: $0.title).tag($0.value) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .accessibilityIdentifier(id)
        case .list(_, let rows):
            VStack(alignment: .leading, spacing: Pixels(4)) {
                ForEach(rows, id: \.key) { row in PluginPanelNodeView(node: row, model: model, send: send).equatable() }
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier(id)
        case .vstack(_, let children):
            VStack(alignment: .leading, spacing: Pixels(6)) {
                ForEach(children, id: \.key) { child in PluginPanelNodeView(node: child, model: model, send: send).equatable() }
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier(id)
        case .hstack(_, let children):
            HStack(spacing: Pixels(6)) {
                ForEach(children, id: \.key) { child in PluginPanelNodeView(node: child, model: model, send: send).equatable() }
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier(id)
        case .divider:
            Divider().accessibilityIdentifier(id)
        }
    }
}

/// A panel text field. Alloy owns the text while the field has focus (or until the plugin changes it): an incoming tree
/// never overwrites what the user is typing. The plugin hears `changed` once after typing stops, `submit` on Return.
struct PluginPanelTextField: Component, Equatable {
    let model: PluginPanelModel
    let send: PluginPanelSender
    let key: String
    let placeholder: String
    let text: String
    let identifier: String
    @State var draft: String?
    @State var base = ""
    @FocusState var focused: Bool

    nonisolated static func == (a: Self, b: Self) -> Bool {
        a.model === b.model && a.send == b.send && a.key == b.key && a.placeholder == b.placeholder && a.text == b.text
            && a.identifier == b.identifier
    }

    var content: some ElementGroup {
        let _ = BodyProbe.hit("PluginPanelTextField")
        let model = model, send = send, key = key, incoming = text
        let state = $draft, baseState = $base
        let shown: String = {
            guard let draft else { return incoming }
            return (focused || incoming == base) ? draft : incoming
        }()
        TextField(placeholder, text: Binding(get: { shown }, set: { new in
            state.wrappedValue = new
            baseState.wrappedValue = incoming
            model.typed(key: key, text: new, send: send)
        }))
        .onSubmit { model.submitted(key: key, text: shown, send: send) }
        .focused($focused)
        .accessibilityIdentifier(identifier)
    }
}
