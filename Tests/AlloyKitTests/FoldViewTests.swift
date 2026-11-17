@testable import AlloyCore
@testable import AlloyKit
import AlloyTestSupport
import Foundation
import MetalUI
import MetalUICodeBuffer
import MetalUITesting
import Testing

/// The chevron lane, the placeholder and the hidden rows in the plain and inline code views.
@MainActor
@Suite struct FoldViewTests {
    static let text = """
    func a() {
        if x {
            b()
        }
    }
    func c() {
        d()
    }

    """

    /// A chat window on `blocks.swift`, with the first build applied.
    private func rigged(text: String = FoldViewTests.text, name: String = "blocks.swift") async throws
        -> (rig: Rig, window: TestWindow, state: CodeFoldState, view: OpenDocumentView) {
        let rig = Rig()
        try text.write(to: rig.root.appendingPathComponent(name), atomically: true, encoding: .utf8)
        rig.workspace.openFilePath = name
        let window = try alloyWindow(rig.workspace)
        try await window.runUntil { (try? window.element(identifier: "code-view")) != nil }
        let doc = try #require(rig.workspace.document(name))
        let view = try #require(CodePanelStore.existingView(for: doc, in: .chat))
        let state = try #require(rig.workspace.foldState(for: name, in: .chat))
        let folds = try #require(view.services.folds)
        for _ in 0..<3000 where folds.buildCount(path: name) == 0 || folds.inFlight(path: name) {
            window.tick(); try? await Task.sleep(nanoseconds: 1_000_000)
        }
        for _ in 0..<10 { window.tick(); await Task.yield() }
        return (rig, window, state, view)
    }

    private func exists(_ window: TestWindow, _ id: String) -> Bool { (try? window.element(identifier: id)) != nil }

    @Test func closedChevronsShowAtRest() async throws {
        let (rig, window, state, _) = try await rigged()
        defer { withExtendedLifetime(rig) {} }
        let first = try #require(state.foldableRanges.first)
        #expect(!exists(window, "fold-placeholder-\(first.lowerBound)"))
        #expect(state.fold(first))
        for _ in 0..<5 { window.tick(); await Task.yield() }
        #expect(exists(window, "fold-placeholder-\(first.lowerBound)"))
        let chevron = try window.element(identifier: "fold-chevron-\(first.lowerBound)")
        #expect(chevron.value == "collapsed")
    }

    @Test func clickingAChevronFoldsAndSchedulesTheWrite() async throws {
        let (rig, window, state, _) = try await rigged()
        defer { withExtendedLifetime(rig) {} }
        let first = try #require(state.foldableRanges.first)
        let element = try window.element(identifier: "fold-chevron-\(first.lowerBound)")
        try window.click(element)
        for _ in 0..<5 { window.tick(); await Task.yield() }
        #expect(!state.folded.isEmpty)
        #expect(rig.workspace.foldSnapshot()["chat"]?["blocks.swift"]?.isEmpty == false)
    }

    @Test func clickingThePlaceholderUnfolds() async throws {
        let (rig, window, state, _) = try await rigged()
        defer { withExtendedLifetime(rig) {} }
        let first = try #require(state.foldableRanges.first)
        #expect(state.fold(first))
        for _ in 0..<5 { window.tick(); await Task.yield() }
        try window.click(try window.element(identifier: "fold-placeholder-\(first.lowerBound)"))
        for _ in 0..<5 { window.tick(); await Task.yield() }
        #expect(state.folded.isEmpty)
    }

    /// The y of the chevron button of `line`, nil when the line is not shown (chevrons are built for shown rows only).
    private func chevronY(_ window: TestWindow, _ line: Int) -> Float? {
        (try? window.element(identifier: "fold-chevron-\(line)"))?.frame.origin.y.value
    }

    @Test func foldedRowsAreHiddenAndTheRowsBelowMoveUp() async throws {
        let (rig, window, state, _) = try await rigged()
        defer { withExtendedLifetime(rig) {} }
        // `func a() {` ... `}` holds a nested `if x {` fold: its chevron is shown now.
        let outer = try #require(state.foldableRanges.first { $0.lowerBound == 0 })
        let below = try #require(state.foldableRanges.first { $0.lowerBound >= outer.upperBound })
        let inner = try #require(state.foldableRanges.first { $0.lowerBound > outer.lowerBound && $0.upperBound <= outer.upperBound })
        let row = try #require(chevronY(window, 1))
        let before = try #require(chevronY(window, below.lowerBound))
        #expect(state.fold(outer))
        for _ in 0..<5 { window.tick(); await Task.yield() }
        #expect(chevronY(window, inner.lowerBound) == nil, "a hidden row has no chevron")
        #expect(exists(window, "fold-placeholder-\(outer.lowerBound)"))
        let after = try #require(chevronY(window, below.lowerBound))
        let pitch = (before - after) / Float(outer.count - 1)
        #expect(pitch > 0, "the lines below moved up: \(before) -> \(after)")
        // The row pitch is the line pitch: the first inner line sat one pitch below the header.
        let header = try #require(chevronY(window, outer.lowerBound))
        #expect(abs(row - header - pitch) < 1.5, "hidden rows are whole lines: pitch \(pitch), \(row - header)")
        #expect(state.isHidden(line: outer.lowerBound + 1) && !state.isHidden(line: outer.lowerBound))
    }

    @Test func plainAndInlineAttachFolds() async throws {
        let (rig, window, state, _) = try await rigged()
        defer { withExtendedLifetime(rig) {} }
        let first = try #require(state.foldableRanges.first)
        #expect(exists(window, "fold-chevron-\(first.lowerBound)"), "the chat (inline) view has the lane")
    }

    @Test func sideBySideAttachesNoneAndTheStateKeepsItsFolds() async throws {
        let (rig, window, state, _) = try await rigged()
        defer { withExtendedLifetime(rig) {} }
        let first = try #require(state.foldableRanges.first)
        #expect(state.fold(first))
        rig.workspace.setPresentation(.sideBySide, of: "blocks.swift", in: .chat)
        for _ in 0..<30 { window.tick(); await Task.yield() }
        #expect(!exists(window, "fold-chevron-\(first.lowerBound)"))
        #expect(state.folded == [first])
        rig.workspace.setPresentation(.inline, of: "blocks.swift", in: .chat)
        for _ in 0..<30 { window.tick(); await Task.yield() }
        #expect(exists(window, "fold-chevron-\(first.lowerBound)"))
    }

    @Test func noFoldableRangeShowsNoChevrons() async throws {
        let (rig, window, state, _) = try await rigged(text: "let a = 1\n", name: "flat.swift")
        defer { withExtendedLifetime(rig) {} }
        #expect(state.foldableRanges.isEmpty)
        #expect(!exists(window, "fold-chevron-0"))
        let (rig2, window2, state2, _) = try await rigged(text: "", name: "empty.swift")
        defer { withExtendedLifetime(rig2) {} }
        #expect(state2.foldableRanges.isEmpty)
        #expect(!exists(window2, "fold-chevron-0"))
    }

    @Test func editAboveAFoldShiftsIt() async throws {
        let (rig, window, state, view) = try await rigged()
        defer { withExtendedLifetime(rig) {} }
        let first = try #require(state.foldableRanges.first { $0.lowerBound > 0 } ?? state.foldableRanges.first)
        #expect(state.fold(first))
        view.document.buffer.replace(0..<0, with: "// c\n")
        for _ in 0..<5 { window.tick(); await Task.yield() }
        #expect(state.folded == [(first.lowerBound + 1)..<(first.upperBound + 1)])
    }

    // MARK: Editor groups, mode switch, hover, compare

    /// Code mode with `login.swift`-like content open in the focused group; returns the group.
    private func codeRig(groups: Int = 1) async throws -> (rig: Rig, window: TestWindow, ids: [UUID]) {
        let rig = Rig()
        try Self.text.write(to: rig.root.appendingPathComponent("blocks.swift"), atomically: true, encoding: .utf8)
        let workspace = rig.workspace
        await workspace.restoreUIState()
        workspace.setMode(.code)
        var ids = [workspace.codeLayout.focusedGroupID]
        await workspace.open("blocks.swift", in: .group(ids[0]))
        if groups > 1 {
            workspace.splitFocused(.horizontal)
            ids.append(workspace.codeLayout.focusedGroupID)
            await workspace.open("blocks.swift", in: .group(ids[1]))
        }
        let window = try alloyWindow(workspace)
        try await window.runUntil { ids.allSatisfy { self.exists(window, "code-group-\($0.uuidString)") } }
        for id in ids {
            let doc = try #require(workspace.document("blocks.swift"))
            let view = try #require(CodePanelStore.existingView(for: doc, in: .group(id)))
            let folds = try #require(view.services.folds)
            for _ in 0..<3000 where folds.buildCount(path: "blocks.swift") == 0 || folds.inFlight(path: "blocks.swift") {
                window.tick(); try? await Task.sleep(nanoseconds: 1_000_000)
            }
        }
        for _ in 0..<10 { window.tick(); await Task.yield() }
        return (rig, window, ids)
    }

    /// The lines whose chevron `group`'s code view shows once the pointer is over its gutter (open chevrons show on
    /// hover only; closed ones always).
    private func shownChevrons(_ window: TestWindow, group: UUID) async throws -> [Int: String] {
        let view = try window.element(identifier: "code-view-\(group.uuidString)").frame
        window.hover(at: Point(x: Pixels(view.origin.x.value + 6), y: Pixels(view.origin.y.value + 6)))
        for _ in 0..<5 { window.tick(); await Task.yield() }
        var found: [Int: String] = [:]
        for e in try window.elements(role: .button) {
            guard let id = e.identifier, id.hasPrefix("fold-chevron-"), let line = Int(id.dropFirst("fold-chevron-".count)) else { continue }
            let f = e.frame
            guard f.origin.x.value >= view.origin.x.value, f.origin.x.value < view.origin.x.value + view.size.width.value,
                  f.origin.y.value >= view.origin.y.value, f.origin.y.value < view.origin.y.value + view.size.height.value else { continue }
            found[line] = e.value
        }
        return found
    }

    @Test func editorGroupPaneHasTheLane() async throws {
        let (rig, window, ids) = try await codeRig()
        defer { withExtendedLifetime(rig) {} }
        let state = try #require(rig.workspace.foldState(for: "blocks.swift", in: .group(ids[0])))
        let first = try #require(state.foldableRanges.first)
        #expect(try await shownChevrons(window, group: ids[0])[first.lowerBound] == "expanded")
        #expect(state.fold(first))
        for _ in 0..<5 { window.tick(); await Task.yield() }
        #expect(exists(window, "fold-placeholder-\(first.lowerBound)"))
        #expect(try await shownChevrons(window, group: ids[0])[first.lowerBound] == "collapsed")
    }

    @Test func twoGroupsOnOneFileFoldIndependently() async throws {
        let (rig, window, ids) = try await codeRig(groups: 2)
        defer { withExtendedLifetime(rig) {} }
        for _ in 0..<30 { window.tick(); await Task.yield() }
        let a = try #require(rig.workspace.foldState(for: "blocks.swift", in: .group(ids[0])))
        let b = try #require(rig.workspace.foldState(for: "blocks.swift", in: .group(ids[1])))
        #expect(a !== b)
        let outer = try #require(a.foldableRanges.first { $0.lowerBound == 0 })
        let inner = try #require(a.foldableRanges.first { $0.lowerBound > 0 && $0.upperBound <= outer.upperBound })
        let before = try await shownChevrons(window, group: ids[0])
        #expect(before[inner.lowerBound] == "expanded", "\(before)")
        #expect(try await shownChevrons(window, group: ids[1])[inner.lowerBound] == "expanded")
        #expect(a.fold(outer))
        for _ in 0..<5 { window.tick(); await Task.yield() }
        let foldedGroup = try await shownChevrons(window, group: ids[0])
        let otherGroup = try await shownChevrons(window, group: ids[1])
        #expect(foldedGroup[outer.lowerBound] == "collapsed" && foldedGroup[inner.lowerBound] == nil, "\(foldedGroup)")
        #expect(otherGroup[outer.lowerBound] == "expanded" && otherGroup[inner.lowerBound] == "expanded", "\(otherGroup)")
        #expect(b.folded.isEmpty && !b.isHidden(line: inner.lowerBound) && a.isHidden(line: inner.lowerBound))
        #expect(b.fold(inner))
        for _ in 0..<5 { window.tick(); await Task.yield() }
        #expect(a.folded == [outer] && b.folded == [inner], "each group keeps its own folds")
        #expect(try await shownChevrons(window, group: ids[0])[inner.lowerBound] == nil)
        #expect(try await shownChevrons(window, group: ids[1])[inner.lowerBound] == "collapsed")
    }

    @Test func foldsSurviveAModeSwitch() async throws {
        let (rig, window, ids) = try await codeRig()
        defer { withExtendedLifetime(rig) {} }
        let state = try #require(rig.workspace.foldState(for: "blocks.swift", in: .group(ids[0])))
        let first = try #require(state.foldableRanges.first)
        #expect(state.fold(first))
        for _ in 0..<5 { window.tick(); await Task.yield() }
        rig.workspace.setMode(.chat)
        for _ in 0..<20 { window.tick(); await Task.yield() }
        rig.workspace.setMode(.code)
        for _ in 0..<20 { window.tick(); await Task.yield() }
        let again = try #require(rig.workspace.foldState(for: "blocks.swift", in: .group(ids[0])))
        #expect(again === state && again.folded == [first], "the fold survived the switch")
        #expect(exists(window, "fold-placeholder-\(first.lowerBound)"))
    }

    @Test func editInAFoldedHeaderKeepsTheFold() async throws {
        let (rig, window, state, view) = try await rigged()
        defer { withExtendedLifetime(rig) {} }
        let first = try #require(state.foldableRanges.first)
        #expect(state.fold(first))
        for _ in 0..<5 { window.tick(); await Task.yield() }
        // Typing at the end of the header line (before its newline) edits the header, not the hidden rows.
        let end = "func a() {".utf8.count
        view.document.buffer.replace(end..<end, with: " // note")
        for _ in 0..<10 { window.tick(); await Task.yield() }
        #expect(state.folded == [first], "the fold stays: \(state.folded)")
        #expect(exists(window, "fold-placeholder-\(first.lowerBound)"))
    }

    @Test func hoveringTheGutterShowsOpenChevrons() async throws {
        let (rig, window, state, _) = try await rigged()
        defer { withExtendedLifetime(rig) {} }
        let first = try #require(state.foldableRanges.first)
        let chevron = try window.element(identifier: "fold-chevron-\(first.lowerBound)")
        try window.hover(chevron)
        for _ in 0..<5 { window.tick(); await Task.yield() }
        let hovered = try window.element(identifier: "fold-chevron-\(first.lowerBound)")
        #expect(hovered.value == "expanded")
        #expect(hovered.frame.size.width.value > 0 && hovered.frame.size.height.value > 0, "the chevron has a cell")
    }

    @Test func compareViewsAttachNoFolds() async throws {
        let perf = CodeModePerformanceTests()
        let (rig, window, _) = try await perf.rigged(.code1, git: true)
        defer { withExtendedLifetime(rig) {} }
        let g = rig.workspace.codeLayout.focusedGroupID
        let doc = try #require(rig.workspace.document("login.swift"))
        let view = try #require(CodePanelStore.existingView(for: doc, in: .group(g)))
        let folds = try #require(view.services.folds)
        for _ in 0..<3000 where folds.buildCount(path: "login.swift") == 0 || folds.inFlight(path: "login.swift") {
            window.tick(); try? await Task.sleep(nanoseconds: 1_000_000)
        }
        rig.workspace.setPresentation(.compareHead, of: "login.swift", in: .group(g))
        for _ in 0..<40 { window.tick(); try? await Task.sleep(nanoseconds: 1_000_000) }
        let chevrons = try window.elements(role: .button).filter { ($0.identifier ?? "").hasPrefix("fold-chevron-") }
        #expect(chevrons.isEmpty, "a compare view shows no chevron lane: \(chevrons.compactMap(\.identifier))")
    }
}
