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
    nonisolated static func == (a: Self, b: Self) -> Bool { a.workspace === b.workspace }
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
            && a.topClear == b.topClear
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

extension DiagnosticCountsBadge: Equatable {
    nonisolated static func == (a: Self, b: Self) -> Bool { a.workspace === b.workspace && a.path == b.path }
}

extension ServerStatusLabel: Equatable {
    nonisolated static func == (a: Self, b: Self) -> Bool { a.workspace === b.workspace && a.path == b.path }
}

extension DefinitionMessage: Equatable {
    nonisolated static func == (a: Self, b: Self) -> Bool { a.view === b.view }
}

extension FilePanelHeader: Equatable {
    nonisolated static func == (a: Self, b: Self) -> Bool {
        a.workspace === b.workspace && a.path == b.path && a.document === b.document && a.view === b.view
    }
}

// Chat children. Each body reads the session (transcript, status, queue, ...) or the composer model through
// observation, so identity of those reference inputs is enough: a change to anything they read re-runs them. The
// session row also takes the workspace's coordination warnings by value, so they are compared.

extension TranscriptView: Equatable {
    nonisolated static func == (a: Self, b: Self) -> Bool {
        a.workspace === b.workspace && a.session === b.session && a.ui === b.ui && a.bottomInset == b.bottomInset
    }
}

extension ComposerView: Equatable {
    nonisolated static func == (a: Self, b: Self) -> Bool {
        a.workspace === b.workspace && a.session === b.session && a.model === b.model && a.style == b.style
    }
}

extension SessionRow: Equatable {
    nonisolated static func == (a: Self, b: Self) -> Bool {
        a.workspace === b.workspace && a.session === b.session && a.warnings == b.warnings
    }
}

extension QueuedCount: Equatable {
    nonisolated static func == (a: Self, b: Self) -> Bool { a.session === b.session }
}
