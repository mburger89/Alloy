@testable import AlloyCore
import AlloyTestSupport
import Foundation
import MetalUICodeBuffer
import Testing

@MainActor @Suite struct FoldPersistenceTests {
    private let text = (0..<30).map { "line \($0)" }.joined(separator: "\n") + "\n"

    private func rig() async -> (Env, PaneID, CodeFoldState) {
        let e = Env()
        e.ws.setMode(.code)
        e.write("a.swift", text)
        let g = e.ws.codeLayout.focusedGroupID
        await e.ws.open("a.swift", in: .group(g))
        return (e, .group(g), e.ws.foldState(for: "a.swift", in: .group(g))!)
    }

    private func choice(_ source: FoldSource, _ ranges: [(Int, Int)]) -> FoldChoice {
        FoldChoice(source: source, ranges: ranges.map { FoldRange(startLine: $0.0, endLine: $0.1) })
    }

    private func apply(_ e: Env, _ c: FoldChoice, version: UInt64? = nil) {
        e.ws.applyFoldRanges(path: "a.swift", choice: c, version: version ?? e.ws.document("a.swift")!.buffer.version)
    }

    @Test func appliedRangesBecomeFoldable() async {
        let (e, _, f) = await rig(); defer { e.cleanup() }
        apply(e, choice(.indentation, [(3, 8)]))
        #expect(f.foldableRanges == [3..<9])
    }

    @Test func rangesAsOfAnOlderVersionShiftWithEdits() async {
        let (e, _, f) = await rig(); defer { e.cleanup() }
        let doc = e.ws.document("a.swift")!
        let old = doc.buffer.version
        _ = doc.buffer.replace(0..<0, with: "new\n")
        apply(e, choice(.indentation, [(3, 8)]), version: old)
        #expect(f.foldableRanges == [4..<10])
    }

    @Test func sourceSwitchKeepsSameStartFolds() async {
        let (e, _, f) = await rig(); defer { e.cleanup() }
        apply(e, choice(.indentation, [(3, 8)]))
        #expect(f.fold(3..<9))
        apply(e, choice(.lsp, [(3, 10), (20, 25)]))
        #expect(f.folded == [3..<11])
        apply(e, choice(.treeSitter, [(4, 10)]))
        #expect(f.folded.isEmpty)
    }

    @Test func sameSourceRebuildLeavesFoldsAlone() async {
        let (e, _, f) = await rig(); defer { e.cleanup() }
        apply(e, choice(.indentation, [(3, 8)]))
        #expect(f.fold(3..<9))
        apply(e, choice(.indentation, [(3, 12)]))
        #expect(f.folded == [3..<9])
    }

    @Test func foldsRoundTripThroughUIState() async throws {
        let (e, pane, f) = await rig(); defer { e.cleanup() }
        apply(e, choice(.indentation, [(3, 8), (12, 20)]))
        #expect(f.fold(3..<9)); #expect(f.fold(12..<21))
        guard case .group(let id) = pane else { return }
        let state = e.ws.currentUIState()
        #expect(state.folds[id.uuidString]?["a.swift"] == [FoldLines(start: 3, end: 8), FoldLines(start: 12, end: 20)])
        let back = try JSONDecoder().decode(UIState.self, from: JSONEncoder().encode(state))
        #expect(back.folds == state.folds)
    }

    @Test func foldsCappedAt2000PerPanePath() async {
        let (e, pane, _) = await rig(); defer { e.cleanup() }
        e.ws.pendingFolds[pane] = ["a.swift": (0..<2500).map { FoldLines(start: $0 * 2, end: $0 * 2 + 1) }]
        e.ws.paneFolds[pane]?["a.swift"] = nil
        let snap = e.ws.foldSnapshot()
        guard case .group(let id) = pane else { return }
        #expect(snap[id.uuidString]?["a.swift"]?.count == 2000)
        #expect(snap[id.uuidString]?["a.swift"]?.last == FoldLines(start: 3998, end: 3999))
    }

    private func restored(_ e: Env, folds: [String: [String: [FoldLines]]]) async {
        let id = e.ws.codeLayout.focusedGroupID
        _ = id
        let state = e.ws.currentUIState()
        var s = state; s.folds = folds
        try? FileManager.default.createDirectory(at: e.ws.storeDirectory, withIntermediateDirectories: true)
        try? UIStateFile.save(s, to: e.ws.uiStateURL)
        await e.ws.restoreUIState()
    }

    @Test func restoreAppliesAfterRangesArrive() async {
        let (e, pane, _) = await rig(); defer { e.cleanup() }
        guard case .group(let id) = pane else { return }
        await restored(e, folds: [id.uuidString: ["a.swift": [FoldLines(start: 3, end: 8)]]])
        await e.ws.open("a.swift", in: .group(e.ws.codeLayout.focusedGroupID))
        let f = e.ws.foldState(for: "a.swift", in: .group(e.ws.codeLayout.focusedGroupID))!
        #expect(f.folded.isEmpty)
        apply(e, choice(.indentation, [(3, 8)]))
        #expect(f.folded == [3..<9])
        #expect(e.ws.pendingFolds.isEmpty)
    }

    @Test func restoreKeepsOnlyFoldsThatStillOpenARange() async {
        let (e, pane, _) = await rig(); defer { e.cleanup() }
        guard case .group(let id) = pane else { return }
        await restored(e, folds: [id.uuidString: ["a.swift": [FoldLines(start: 3, end: 8), FoldLines(start: 10, end: 14),
                                                              FoldLines(start: 25, end: 90)]]])
        await e.ws.open("a.swift", in: .group(e.ws.codeLayout.focusedGroupID))
        let f = e.ws.foldState(for: "a.swift", in: .group(e.ws.codeLayout.focusedGroupID))!
        apply(e, choice(.indentation, [(3, 9), (25, 29)]))
        #expect(f.folded == [3..<10])
        #expect(e.ws.pendingFolds.isEmpty)
    }

    @Test func restoreDropsRemovedPathAndGroup() async {
        let (e, pane, _) = await rig(); defer { e.cleanup() }
        guard case .group(let id) = pane else { return }
        await restored(e, folds: [id.uuidString: ["a.swift": [FoldLines(start: 3, end: 8)], "gone.swift": [FoldLines(start: 1, end: 3)]],
                                  UUID().uuidString: ["a.swift": [FoldLines(start: 3, end: 8)]]])
        #expect(e.ws.pendingFolds.count == 1)
        #expect(e.ws.pendingFolds.values.first?.keys.sorted() == ["a.swift"])
    }

    @Test func pendingWaitsForAMatchingVersion() async {
        let (e, pane, _) = await rig(); defer { e.cleanup() }
        guard case .group(let id) = pane else { return }
        await restored(e, folds: [id.uuidString: ["a.swift": [FoldLines(start: 3, end: 8)]]])
        await e.ws.open("a.swift", in: .group(e.ws.codeLayout.focusedGroupID))
        let doc = e.ws.document("a.swift")!
        let f = e.ws.foldState(for: "a.swift", in: .group(e.ws.codeLayout.focusedGroupID))!
        let built = doc.buffer.version
        _ = doc.buffer.replace(0..<0, with: "x")
        e.ws.applyFoldRanges(path: "a.swift", choice: choice(.indentation, [(3, 8)]), version: built)
        #expect(f.folded.isEmpty)
        #expect(!e.ws.pendingFolds.isEmpty)
        apply(e, choice(.indentation, [(3, 8)]))
        #expect(f.folded == [3..<9])
        #expect(e.ws.pendingFolds.isEmpty)
    }

    @Test func pendingSurvivesAnotherWriteBeforeRanges() async {
        let (e, pane, _) = await rig(); defer { e.cleanup() }
        guard case .group(let id) = pane else { return }
        await restored(e, folds: [id.uuidString: ["a.swift": [FoldLines(start: 3, end: 8)]]])
        #expect(e.ws.currentUIState().folds[id.uuidString]?["a.swift"] == [FoldLines(start: 3, end: 8)])
        await e.ws.open("a.swift", in: .group(e.ws.codeLayout.focusedGroupID))
        #expect(e.ws.currentUIState().folds[id.uuidString]?["a.swift"] == [FoldLines(start: 3, end: 8)])
    }

    @Test func closingTheTabClearsPending() async {
        let (e, pane, _) = await rig(); defer { e.cleanup() }
        guard case .group(let id) = pane else { return }
        await restored(e, folds: [id.uuidString: ["a.swift": [FoldLines(start: 3, end: 8)]]])
        let g = e.ws.codeLayout.focusedGroupID
        await e.ws.open("a.swift", in: .group(g))
        await e.ws.close("a.swift", in: .group(g))
        #expect(e.ws.pendingFolds.values.allSatisfy { $0["a.swift"] == nil })
        #expect(e.ws.latestFold["a.swift"] == nil)
    }

    @Test func savingSchedulesAWriteOnlyWithFolds() async throws {
        let (e, _, f) = await rig(); defer { e.cleanup() }
        await e.ws.restoreUIState()
        await e.ws.open("a.swift", in: .group(e.ws.codeLayout.focusedGroupID))
        let f2 = e.ws.foldState(for: "a.swift", in: .group(e.ws.codeLayout.focusedGroupID)) ?? f
        e.ws.uiStateTimer?.cancel(); e.ws.uiStateTimer = nil
        _ = e.ws.document("a.swift")!.buffer.replace(0..<0, with: "x")
        try await e.ws.save("a.swift", format: false)
        #expect(e.ws.uiStateTimer == nil)
        apply(e, choice(.indentation, [(3, 8)]))
        #expect(f2.fold(3..<9))
        _ = e.ws.document("a.swift")!.buffer.replace(0..<0, with: "y")
        try await e.ws.save("a.swift", format: false)
        #expect(e.ws.uiStateTimer != nil)
    }

    @Test func editsAloneDoNotScheduleAWrite() async {
        let (e, _, f) = await rig(); defer { e.cleanup() }
        await e.ws.restoreUIState()
        e.ws.uiStateTimer?.cancel(); e.ws.uiStateTimer = nil
        apply(e, choice(.indentation, [(3, 8)]))
        #expect(f.fold(3..<9))
        _ = e.ws.document("a.swift")!.buffer.replace(0..<0, with: "x")
        #expect(e.ws.uiStateTimer == nil)
    }

    @Test func noteFoldsChangedSchedulesTheDebouncedWrite() async {
        let (e, _, _) = await rig(); defer { e.cleanup() }
        await e.ws.restoreUIState()
        e.ws.uiStateTimer?.cancel(); e.ws.uiStateTimer = nil
        e.ws.noteFoldsChanged()
        #expect(e.ws.uiStateTimer != nil)
    }

    @Test func refusedRangesLeaveFoldsAndBaselineAlone() async {
        let (e, _, f) = await rig(); defer { e.cleanup() }
        apply(e, choice(.indentation, [(3, 8)]))
        #expect(f.fold(3..<9))
        let future = e.ws.document("a.swift")!.buffer.version + 100
        apply(e, choice(.lsp, [(3, 10)]), version: future)
        #expect(f.folded == [3..<9])
        #expect(f.foldableRanges == [3..<9])
        #expect(e.ws.latestFold["a.swift"]?.choice.source == .indentation)
    }

    @Test func restoreAppliesAtOnceWhenRangesAreAlreadyThere() async {
        let (e, pane, _) = await rig(); defer { e.cleanup() }
        guard case .group(let id) = pane else { return }
        apply(e, choice(.indentation, [(3, 8)]))
        await restored(e, folds: [id.uuidString: ["a.swift": [FoldLines(start: 3, end: 8)]]])
        let f = e.ws.foldState(for: "a.swift", in: pane)!
        #expect(f.folded == [3..<9])
        #expect(e.ws.pendingFolds.isEmpty)
    }

    @Test func replacingTheDocumentClearsTheRangeBaseline() async {
        let (e, _, _) = await rig(); defer { e.cleanup() }
        apply(e, choice(.indentation, [(3, 8)]))
        #expect(e.ws.latestFold["a.swift"] != nil)
        e.ws.install(.text(Array(text.utf8), FileStamp(modified: nil, size: text.utf8.count), truncated: false),
                     path: "a.swift", url: URL(fileURLWithPath: "a.swift"))
        #expect(e.ws.latestFold["a.swift"] == nil)
    }

    @Test func snapshotUnionsPendingWithLiveFolds() async {
        let (e, pane, f) = await rig(); defer { e.cleanup() }
        guard case .group(let id) = pane else { return }
        await restored(e, folds: [id.uuidString: ["a.swift": [FoldLines(start: 3, end: 8)]]])
        let live = e.ws.foldState(for: "a.swift", in: pane) ?? f
        #expect(live.fold(12..<16))
        let saved = e.ws.currentUIState().folds[id.uuidString]?["a.swift"] ?? []
        #expect(saved.sorted { $0.start < $1.start } == [FoldLines(start: 3, end: 8), FoldLines(start: 12, end: 15)])
    }

    @Test func pendingMergesWithFoldsMadeBeforeItApplies() async {
        let (e, pane, _) = await rig(); defer { e.cleanup() }
        guard case .group(let id) = pane else { return }
        await restored(e, folds: [id.uuidString: ["a.swift": [FoldLines(start: 3, end: 8)]]])
        let f = e.ws.foldState(for: "a.swift", in: pane)!
        #expect(f.fold(12..<16))
        apply(e, choice(.indentation, [(3, 8), (12, 15)]))
        #expect(Set(f.folded) == [3..<9, 12..<16])
    }
}
