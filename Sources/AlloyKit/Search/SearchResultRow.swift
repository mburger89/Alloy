import AlloyCore
import Foundation
import MetalUI

let searchRowGap = Pixels(6)
let searchLineFont = "Menlo"

/// The summary, the inline error, the stale note and the results list. The only reader of the model's result state.
struct SearchResultsView: Component {
    let workspace: Workspace

    var content: some ElementGroup {
        let _ = BodyProbe.hit("SearchResultsView")
        let workspace = workspace
        let model = workspace.search
        let groups = model.groups
        let selection = model.selection
        let replaceShown = workspace.searchReplaceRevealed
        if let review = model.review {
            SearchReviewList(workspace: workspace, review: review)
        } else {
        VStack(alignment: .leading, spacing: Pixels(4)) {
            if let error = model.error {
                Text(verbatim: error).font(size: searchFontSize).foregroundColor(.errorInk)
                    .accessibilityIdentifier("search-error")
            }
            Text(verbatim: model.summary).font(size: searchFontSize).foregroundColor(.mutedInk)
                .accessibilityIdentifier("search-summary")
            if model.isStale {
                HStack(spacing: searchRowGap) {
                    Text(verbatim: "Results may be out of date").font(size: searchFontSize).foregroundColor(.mutedInk)
                    Button("Re-run") { model.rerun() }
                        .buttonStyle(.plain).foregroundColor(.accentColor)
                        .accessibilityIdentifier("search-rerun")
                }
            }
            ScrollViewReader { proxy in
                ProposalScrollView {
                    List {
                        ForEach(Array(groups.enumerated()), id: \.element.index) { position, group in
                            SearchResultRow(workspace: workspace, group: group, position: position,
                                            selectedLine: selection?.file == position ? selection?.line : nil,
                                            replaceShown: replaceShown).equatable()
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .onChange(of: selection) { _, new in
                    if let new, groups.indices.contains(new.file) { proxy.scrollTo(groups[new.file].index) }
                }
            }
        }
        .onAppear { model.tabShown() }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("search-results")
        }
    }
}

/// One file: a disclosure over its previews. Equatable, so a batch that appends groups does not rebuild the rows
/// already built, and an arrow key rebuilds only the row whose selected line changed.
struct SearchResultRow: Component, Equatable {
    let workspace: Workspace
    let group: SearchGroup
    let position: Int
    let selectedLine: Int?
    let replaceShown: Bool
    @State var expanded = true
    @State var hovering = false

    nonisolated static func == (a: Self, b: Self) -> Bool {
        a.workspace === b.workspace && a.position == b.position && a.selectedLine == b.selectedLine
            && a.replaceShown == b.replaceShown
            && a.group.index == b.group.index && a.group.path == b.group.path && a.group.matches.count == b.group.matches.count
    }

    var content: some ElementGroup {
        let _ = BodyProbe.hit("SearchResultRow")
        let group = group, position = position, selectedLine = selectedLine, workspace = workspace
        let replaceShown = replaceShown
        let model = workspace.search
        VStack(alignment: .leading, spacing: 0) {
        DisclosureGroup(isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(group.matches.enumerated()), id: \.offset) { line, match in
                    SearchPreviewRow(match: match, selected: selectedLine == line,
                                     open: { model.open(file: position, line: line) },
                                     dismiss: { model.dismiss(file: position, line: line) },
                                     replace: replaceShown ? { model.replace(file: position, line: line) } : nil,
                                     position: position, line: line)
                }
            }
        } label: {
            HStack(spacing: searchRowGap) {
                Text(verbatim: group.name).font(size: searchFontSize).lineLimit(1)
                Text(verbatim: group.folder).font(size: searchFontSize).foregroundColor(.mutedInk).lineLimit(1)
                Spacer()
                Text(verbatim: "\(group.matches.count)").font(size: searchFontSize).foregroundColor(.mutedInk)
                if hovering {
                    if replaceShown {
                        Button { model.replace(file: position) } label: {
                            Image(systemName: "arrow.2.squarepath").font(.system(size: 10)).foregroundColor(.mutedInk)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Replace in File")
                        .accessibilityIdentifier("search-replace-file-\(position)")
                    }
                    Button { model.dismiss(file: position) } label: {
                        Image(systemName: "xmark").font(.system(size: 10)).foregroundColor(.mutedInk)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Dismiss")
                    .accessibilityIdentifier("search-dismiss-\(position)")
                }
            }
            .onHover { hovering = $0 }
        }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("search-file-\(position)")
    }
}

/// One preview: line number and the line with the match highlighted. Click opens it.
struct SearchPreviewRow: Component {
    let match: SearchMatch
    let selected: Bool
    let open: () -> Void
    let dismiss: () -> Void
    let replace: (() -> Void)?
    let position: Int
    let line: Int
    @State var hovering = false

    /// The preview text with a background run over the match.
    static func attributed(_ match: SearchMatch) -> AttributedString {
        let bytes = Array(match.preview.utf8)
        let m = match.previewMatch
        guard m.lowerBound >= 0, m.upperBound <= bytes.count, m.lowerBound < m.upperBound else { return AttributedString(match.preview) }
        func piece(_ r: Range<Int>) -> AttributedString { AttributedString(String(decoding: bytes[r], as: UTF8.self)) }
        var out = piece(0..<m.lowerBound)
        var hit = piece(m)
        hit.backgroundColor = .findMatchFill
        out.append(hit)
        out.append(piece(m.upperBound..<bytes.count))
        return out
    }

    var content: some ElementGroup {
        let match = match, open = open, dismiss = dismiss
        HStack(spacing: searchRowGap) {
            Text(verbatim: "\(match.line)").font(family: searchLineFont, size: 11).foregroundColor(.mutedInk)
                .frame(width: Pixels(36), alignment: .trailing)
            Text(Self.attributed(match)).font(family: searchLineFont, size: 11).lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
            if hovering {
                if let replace {
                    Button { replace() } label: {
                        Image(systemName: "arrow.2.squarepath").font(.system(size: 10)).foregroundColor(.mutedInk)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Replace Match")
                    .accessibilityIdentifier("search-replace-line-\(position)-\(line)")
                }
                Button { dismiss() } label: {
                    Image(systemName: "xmark").font(.system(size: 10)).foregroundColor(.mutedInk)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Dismiss")
                .accessibilityIdentifier("search-dismiss-\(position)-\(line)")
            }
        }
        .padding(inset(4, 2))
        .background(selected ? Color.commandTint : Color.clear)
        .onTapGesture { open() }
        .onHover { hovering = $0 }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("search-line-\(position)-\(line)")
    }
}
