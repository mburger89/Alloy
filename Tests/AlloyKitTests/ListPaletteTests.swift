@testable import AlloyKit
import Foundation
import Testing

@MainActor
@Suite struct ListPaletteTests {
    private func items(_ titles: [String]) -> [ListPaletteModel.Item] {
        titles.enumerated().map { ListPaletteModel.Item(title: $1, tag: $0) }
    }

    private func settle(_ model: ListPaletteModel, landed: Int) async {
        for _ in 0..<500_000 where model.landedCount < landed { await Task.yield() }
    }

    @Test func emptyQueryKeepsSourceOrder() {
        let model = ListPaletteModel(kind: .symbols, items: items(["zeta", "alpha", "mid"])) { _ in }
        #expect(model.rows.map(\.title) == ["zeta", "alpha", "mid"])
        #expect(model.footer == nil)
    }

    @Test func fuzzyFilterNarrows() async {
        let model = ListPaletteModel(kind: .symbols, items: items(["parseHeader", "render", "parseBody", "other"])) { _ in }
        model.setQuery("pars")
        await settle(model, landed: 1)
        #expect(Set(model.rows.map(\.title)) == ["parseHeader", "parseBody"])
        model.setQuery("")
        #expect(model.rows.count == 4)
    }

    @Test func anOlderFilteringIsDropped() async {
        let model = ListPaletteModel(kind: .symbols, items: items(["alpha", "beta", "gamma"])) { _ in }
        let gate = PaletteGate()
        model.rankGate = { query in if query == "al" { await gate.wait() } }
        model.setQuery("al")
        model.rankGate = nil
        model.setQuery("be")
        await settle(model, landed: 1)
        #expect(model.rows.map(\.title) == ["beta"])
        await gate.open()
        for _ in 0..<2_000 { await Task.yield() }
        #expect(model.rows.map(\.title) == ["beta"])
    }

    @Test func returnPicksTheSelectedRow() {
        var picked: [Int] = []
        let model = ListPaletteModel(kind: .symbols, items: items(["a", "b", "c"])) { picked.append($0.tag) }
        model.move(1)
        model.move(1)
        model.move(1)
        #expect(model.selected == 2)
        model.submit()
        #expect(picked == [2])
    }

    @Test func zeroItemsShowOneInertRowThatReturnIgnores() {
        var picked = 0
        let symbols = ListPaletteModel(kind: .symbols, items: []) { _ in picked += 1 }
        #expect(symbols.rows.count == 1 && symbols.rows[0].inert && symbols.rows[0].title == "No symbols for this file")
        symbols.submit()
        symbols.pick(0)
        let refs = ListPaletteModel(kind: .references, items: []) { _ in picked += 1 }
        #expect(refs.rows.first?.title == "No references found")
        #expect(picked == 0)
    }

    @Test func aFilterThatMatchesNothingShowsTheInertRow() async {
        let model = ListPaletteModel(kind: .symbols, items: items(["alpha"])) { _ in }
        model.setQuery("zzz")
        await settle(model, landed: 1)
        #expect(model.rows.count == 1 && model.rows[0].inert)
    }

    @Test func fiveThousandItemsShowFiftyRowsAndAFooter() {
        let model = ListPaletteModel(kind: .references, items: items((0..<5_000).map { "row\($0)" }), note: "3 more outside the project") { _ in }
        #expect(model.rows.count == 50)
        #expect(model.hiddenCount == 4_950)
        #expect(model.footer == "4950 more  ·  3 more outside the project")
    }

    @Test func loadingShowsAWaitingRowUntilItemsArrive() {
        let model = ListPaletteModel(kind: .symbols, items: [], loading: true) { _ in }
        #expect(model.rows.count == 1 && model.rows[0].inert && model.rows[0].title != "No symbols for this file")
        model.setItems(items(["x"]))
        #expect(model.rows.map(\.title) == ["x"])
    }
}

private actor PaletteGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var opened = false
    func wait() async {
        if opened { return }
        await withCheckedContinuation { continuation = $0 }
    }
    func open() {
        opened = true
        continuation?.resume()
        continuation = nil
    }
}
