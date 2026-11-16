import AlloyCore
import Foundation
import MetalUI

let fileTreeFontSize: Double = 12
let fileTreeIconSize: Double = 11
let fileTreeMarkSize = Pixels(7)
let fileTreeRowGap = Pixels(6)
let fileTreeNoteText = "Large project: the tree lists only part of the files."

/// Code mode's file tree: folders first, each folder open or closed by `FileTreeModel`, a colour dot on the files and
/// folders the ledger says changed. Return and double-click open a file in the focused group.
struct FileTreeView: Component {
    let workspace: Workspace

    private var selection: Binding<String?> {
        let workspace = workspace
        return Binding(get: { workspace.fileTreeSelection }, set: { workspace.fileTreeSelection = $0 })
    }

    var content: some ElementGroup {
        let _ = BodyProbe.hit("FileTreeView")
        let workspace = workspace
        let tree = workspace.fileTree
        let roots = tree.snapshot.children(of: "")
        VStack(alignment: .leading, spacing: 0) {
            ScrollViewReader { proxy in
                ProposalScrollView {
                    List(selection: selection) {
                        ForEach(roots, id: \.path) { FileTreeNodeRow(workspace: workspace, entry: $0) }
                    }
                    .contextMenu(forSelectionType: String.self, menu: { _ in }, primaryAction: { paths in
                        for path in paths.sorted() where workspace.fileTree.snapshot.contains(path) && !workspace.fileTree.snapshot.isFolder(path) {
                            workspace.requestOpen(path, in: workspace.defaultPane)
                        }
                    })
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .onAppear { workspace.fileTreeScroll = { proxy.scrollTo($0) } }
            }
            if tree.snapshot.truncated {
                Text(verbatim: fileTreeNoteText).font(size: fileTreeFontSize).foregroundColor(.mutedInk)
                    .padding(inset(12, 8))
                    .accessibilityIdentifier("file-tree-truncated")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { workspace.fileTreeViewAppeared() }
        .onDisappear { workspace.fileTreeViewDisappeared() }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("file-tree")
    }
}

/// One row: a folder is a disclosure over its children, a file a plain row. Everything conditional lives here, never
/// directly in the `List`, so the list stays lazy and selectable.
struct FileTreeNodeRow: Component {
    let workspace: Workspace
    let entry: FileTreeEntry

    @ElementBuilder var content: some ElementGroup {
        if entry.isFolder {
            let expansion = workspace.fileTree.expansion(for: entry.path)
            let expanded = Binding(get: { expansion.isExpanded }, set: { [workspace] value in
                guard expansion.isExpanded != value else { return }
                expansion.isExpanded = value
                workspace.noteExpandedFoldersChanged()
            })
            DisclosureGroup(isExpanded: expanded) {
                ForEach(workspace.fileTree.snapshot.children(of: entry.path), id: \.path) {
                    FileTreeNodeRow(workspace: workspace, entry: $0)
                }
            } label: {
                FileTreeLabel(workspace: workspace, entry: entry)
            }
        } else {
            FileTreeLabel(workspace: workspace, entry: entry)
        }
    }
}

/// The icon, the name and the change mark of one entry.
struct FileTreeLabel: Component {
    let workspace: Workspace
    let entry: FileTreeEntry

    var content: some ProposalElementGroup {
        let mark = workspace.fileTree.marks[entry.path]
        HStack(spacing: fileTreeRowGap) {
            Image(systemName: entry.isFolder ? "folder" : "doc").font(.system(size: fileTreeIconSize)).foregroundColor(.mutedInk)
            Text(verbatim: entry.name).font(size: fileTreeFontSize)
            Spacer()
            if let mark {
                Circle().fill(Self.color(mark, sessions: workspace.sessions)).frame(width: fileTreeMarkSize, height: fileTreeMarkSize)
                    .accessibilityIdentifier("file-tree-mark-\(entry.path)")
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("file-tree-row-\(entry.path)")
    }

    @MainActor static func color(_ mark: ChangeMark, sessions: [Session]) -> Color {
        switch mark {
        case .author(let author): authorColor(author, sessions: sessions)
        case .mixed: .mutedInk
        }
    }
}
