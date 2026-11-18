#if !os(Windows)

@testable import AlloyTerminal
import AlloyCore
import AlloyTestSupport
import Foundation
import MetalUITerminal
import Testing

private let size = TerminalSize(cols: 80, rows: 24)

private func make(lines: Int = 200) -> (TerminalSnapshotSource, TerminalScreen) {
    let source = TerminalSnapshotSource(emulator: TerminalEmulator(cols: 80, rows: 24, scrollback: 1000),
                                        queue: DispatchQueue(label: "screen.test"))
    let text = (1...lines).map { "line \($0)" }.joined(separator: "\r\n")
    Array(text.utf8).withUnsafeBytes { source.feed($0) }
    return (source, TerminalScreen(source: source, viewportRows: { 24 }))
}

private func inspect<T: Sendable>(_ source: TerminalSnapshotSource, _ body: @escaping @Sendable (TerminalEmulator) -> T) async -> T {
    await withCheckedContinuation { c in source.perform { c.resume(returning: body($0)) } }
}

struct TerminalScreenTests {
    @Test func selectAllSelectsEveryScrollbackRow() async {
        let (_, screen) = make()
        await screen.selectAll()
        let text = await screen.selectedText() ?? ""
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        #expect(lines.first == "line 1")
        #expect(lines.last == "line 200")
        #expect(lines.count == 200)
        #expect(lines.allSatisfy { !$0.hasSuffix(" ") })
    }

    @Test func selectAllOnAnEmptyScreenIsHarmless() async {
        let (_, screen) = make(lines: 1)
        await screen.selectAll()
        #expect(await screen.selectedText() != nil)
        await screen.clearSelection()
        #expect(await screen.selectedText() == nil)
    }

    @Test func clearScrollbackDropsHistoryKeepsScreen() async {
        let (source, screen) = make()
        await screen.clearScrollback()
        let (first, rows) = await inspect(source) { e in
            (e.firstRow, (e.firstRow..<(e.firstRow + 100)).compactMap { e.rowText($0) }.filter { !$0.isEmpty })
        }
        #expect(rows.count == 24)
        #expect(rows.first == "line 177")
        #expect(rows.last == "line 200")
        await screen.selectAll()
        let text = await screen.selectedText() ?? ""
        #expect(!text.contains("line 1\n"))
        #expect(first >= 0)
    }

    @Test func searchFindsAcrossScrollbackBothWays() async {
        let (_, screen) = make()
        let back = await screen.search("line 1", from: nil, backwards: true)
        #expect(back?.lowerBound.row != nil)
        let firstHit = await screen.search("line 1", from: TerminalPosition(row: 0, col: 0), backwards: false)
        #expect(firstHit?.lowerBound == TerminalPosition(row: 0, col: 0))
        let last = await screen.search("line 200", from: nil, backwards: false)
        #expect(last != nil)
        #expect(await screen.search("line 200", from: last!.lowerBound, backwards: true) == nil)
        let past = TerminalPosition(row: last!.lowerBound.row, col: last!.lowerBound.col + 1)
        #expect(await screen.search("line 200", from: past, backwards: false) == nil)
        #expect(await screen.search("nothing here", from: nil, backwards: false) == nil)
    }

    @Test func findWrapsAtBothEnds() async {
        let (source, screen) = make()
        let row = { await inspect(source) { e in e.selection.map { if case .linear(let r) = $0 { r.lowerBound.row } else { -1 } } } }
        // "line 19" matches 19 and 190...199: forward from the end wraps to the oldest match, backwards the reverse.
        let a = await screen.find("line 19", backwards: false, inclusive: true)
        #expect(a?.lowerBound.row == 18)
        var last = a
        for _ in 0..<11 { last = await screen.find("line 19", backwards: false) }
        #expect(last?.lowerBound.row == 18, "eleven matches, the twelfth wraps")
        #expect(await row() == 18)
        let back = await screen.find("line 19", backwards: true)
        #expect(back?.lowerBound.row == 198)
        #expect(await screen.find("nothing here", backwards: false) == nil)
        #expect(await row() == 198, "no match keeps the selection")
        #expect(await screen.find("", backwards: false) == nil)
    }

    @Test func searchEmptyNeedleIsNil() async {
        let (_, screen) = make()
        #expect(await screen.search("", from: nil, backwards: false) == nil)
    }

    @Test func revealScrollsTheViewportToAMatchInScrollback() async {
        let (source, screen) = make()
        let match = await screen.search("line 5", from: nil, backwards: false)
        #expect(match != nil)
        await screen.reveal(match!)
        let snapshot = await inspect(source) { $0.publishSnapshot() }
        #expect(snapshot.viewportOffset > 0)
        #expect(snapshot.selection == .linear(match!))
        let row = match!.lowerBound.row
        let top = await inspect(source) { e in e.firstRow }
        #expect(row >= top)
        // A match on the live screen leaves the viewport at the bottom.
        let live = await screen.search("line 200", from: nil, backwards: false)!
        await screen.reveal(live)
        let after = await inspect(source) { $0.publishSnapshot() }
        #expect(after.viewportOffset == 0)
    }

    @Test func revealedMatchIsInsideTheViewport() async {
        let (source, screen) = make()
        let match = await screen.search("line 50", from: nil, backwards: false)!
        await screen.reveal(match)
        let snapshot = await inspect(source) { $0.publishSnapshot() }
        let last = await inspect(source) { e -> Int in
            var r = e.firstRow
            while e.rowText(r + 1) != nil { r += 1 }
            return r
        }
        let top = last - 23 - snapshot.viewportOffset
        #expect((top...(top + 23)).contains(match.lowerBound.row))
    }

    @Test func selectionReachesTheNextSnapshot() async {
        let (source, screen) = make()
        await screen.selectAll()
        let snapshot = await inspect(source) { $0.publishSnapshot() }
        #expect(snapshot.selection != nil)
    }

    @Test func modesReflectTheEmulator() async {
        let (source, screen) = make(lines: 1)
        Array("\u{1B}[?2004h".utf8).withUnsafeBytes { source.feed($0) }
        #expect(await screen.modes().bracketedPaste)
    }

    @MainActor @Test func screenIsNilWithoutASession() {
        let manager = TerminalManager(spawner: ScriptedPtySpawner(), settings: { TerminalSettings() },
                                      projectRoot: NSTemporaryDirectory(), environment: ["SHELL": "/bin/sh"],
                                      home: NSTemporaryDirectory(), delegate: .init())
        let id = UUID()
        #expect(manager.screen(for: id) == nil)
        manager.spawnIfNeeded([(id: id, cwd: nil)])
        #expect(manager.screen(for: id) != nil)
    }
}

#endif
