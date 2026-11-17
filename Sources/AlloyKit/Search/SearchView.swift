import AlloyCore
import Foundation
import MetalUI

let searchFontSize: Double = 12
let searchMatchCaseHelp = "Match Case. Non-ASCII case folding is exact only in regex mode"

/// The Search tab: the query field with its option toggles, a globs disclosure and (after Replace in Files) a replace
/// row, over the results. This view never reads results, selection or stale state (`SearchResultsView` does), so
/// streaming batches and keystrokes in an editor do not re-run it.
struct SearchView: Component {
    let workspace: Workspace

    @FocusState var fieldFocused: Bool

    private func binding<T>(_ key: WritableKeyPath<SearchQuery, T>) -> Binding<T> {
        let model = workspace.search
        return Binding(get: { model.query[keyPath: key] }, set: { value in
            var next = model.query
            next[keyPath: key] = value
            model.setQuery(next)
        })
    }

    var content: some ElementGroup {
        let _ = BodyProbe.hit("SearchView")
        let workspace = workspace
        let model = workspace.search
        VStack(alignment: .leading, spacing: Pixels(6)) {
            HStack(spacing: Pixels(4)) {
                TextField("Search", text: binding(\.text))
                    .onSubmit { model.submitOrOpen() }
                    .focused($fieldFocused)
                    .onAppear { fieldFocused = true }
                    .onChange(of: model.focusToken) { _, _ in fieldFocused = true }
                    .onKeyPress(phases: [.down, .repeat]) { press in
                        guard press.modifiers.isEmpty else { return .ignored }
                        switch press.key {
                        case .downArrow: model.moveSelection(1); return .handled
                        case .upArrow: model.moveSelection(-1); return .handled
                        case .escape: model.cancel(); return .handled
                        default: return .ignored
                        }
                    }
                    .accessibilityIdentifier("search-query")
                Toggle(isOn: binding(\.caseSensitive)) { Text("Aa").font(size: searchFontSize) }
                    .toggleStyle(.button).help(searchMatchCaseHelp)
                    .accessibilityLabel("Match Case").accessibilityIdentifier("search-opt-case")
                Toggle(isOn: binding(\.wholeWord)) { Text("ab").font(size: searchFontSize) }
                    .toggleStyle(.button).help("Whole Word")
                    .accessibilityLabel("Whole Word").accessibilityIdentifier("search-opt-word")
                Toggle(isOn: binding(\.regex)) { Text(".*").font(size: searchFontSize) }
                    .toggleStyle(.button).help("Regular Expression")
                    .accessibilityLabel("Regular Expression").accessibilityIdentifier("search-opt-regex")
            }
            if workspace.searchReplaceRevealed { SearchReplaceBar(workspace: workspace) }
            VStack(alignment: .leading, spacing: 0) {
                DisclosureGroup(isExpanded: Binding(get: { model.globsOpen }, set: { model.globsOpen = $0 })) {
                    VStack(alignment: .leading, spacing: Pixels(4)) {
                        TextField("Include, e.g. *.swift", text: binding(\.include)).accessibilityIdentifier("search-include")
                        TextField("Exclude, e.g. Tests/**", text: binding(\.exclude)).accessibilityIdentifier("search-exclude")
                    }
                } label: {
                    Text("Files to include or exclude").font(size: searchFontSize)
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("search-globs")
            SearchResultsView(workspace: workspace)
        }
        .padding(inset(10, 6))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("search-view")
    }
}
