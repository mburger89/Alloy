import Foundation

/// Keeps Chat's tabs and Code mode's focused group showing the same file across a mode switch. Documents are shared,
/// so nothing is saved, read or reopened: only tab lists and active tabs change.
extension Workspace {
    /// Sets Chat's active tab; with `saving: false` the previous tab is left as it is (a mode switch never writes).
    func setChatActive(_ path: String?, saving: Bool) {
        if saving { activeTab = path; return }
        activeTabChangeIsSilent = true
        activeTab = path
        activeTabChangeIsSilent = false
    }

    /// Switching to Chat: the focused group's file becomes Chat's active tab, appended when Chat lacks it.
    func syncChatToFocusedGroup() {
        guard let path = codeLayout.focusedGroup.activeTab else { return }
        addTab(path, in: .chat)
        setChatActive(path, saving: false)
    }

    /// Switching to Code with a single empty group: Chat's active tab opens there (the first switch is not an empty editor).
    func seedEmptyGroupFromChat() {
        guard codeLayout.groups.count == 1, codeLayout.focusedGroup.tabs.isEmpty, let path = activeTab else { return }
        let id = codeLayout.focusedGroupID
        addTab(path, in: .group(id))
        codeLayout.focusedGroup.activeTab = path
    }
}
