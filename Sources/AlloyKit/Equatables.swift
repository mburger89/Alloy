import AlloyCore
import MetalUI

// The window rebuilds every non-`.equatable()` component each frame. These four screen-level components take only
// reference-type models (read through observation) so identity is their whole value: `.equatable()` then skips
// their `content` until a property they read changes. A `Binding` input is a value: its current `wrappedValue` is
// compared, so the pane is evaluated again when the state it stands for is written from elsewhere.

extension AlloyScreen: Equatable {
    nonisolated static func == (a: Self, b: Self) -> Bool { a.workspace === b.workspace && a.themes === b.themes }
}

extension SidebarView: Equatable {
    nonisolated static func == (a: Self, b: Self) -> Bool {
        MainActor.assumeIsolated { a.workspace === b.workspace && a.showSettings == b.showSettings }
    }
}

extension ChatView: Equatable {
    nonisolated static func == (a: Self, b: Self) -> Bool { a.workspace === b.workspace && a.store === b.store }
}

extension FilePanelView: Equatable {
    nonisolated static func == (a: Self, b: Self) -> Bool {
        a.workspace === b.workspace && a.store === b.store && a.panel === b.panel && a.quickOpen === b.quickOpen
    }
}

extension CodePanel: Equatable {
    nonisolated static func == (a: Self, b: Self) -> Bool {
        a.workspace === b.workspace && a.store === b.store && a.document === b.document && a.view === b.view
    }
}

extension ChatColumn: Equatable {
    nonisolated static func == (a: Self, b: Self) -> Bool {
        a.workspace === b.workspace && a.session === b.session && a.ui === b.ui
    }
}

extension FileTabStrip: Equatable {
    nonisolated static func == (a: Self, b: Self) -> Bool { a.workspace === b.workspace }
}

extension FilePanelHeader: Equatable {
    nonisolated static func == (a: Self, b: Self) -> Bool {
        a.workspace === b.workspace && a.path == b.path && a.document === b.document && a.view === b.view
    }
}
