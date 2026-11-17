import AlloyCore
import AlloyLSP
@testable import AlloyKit
import AlloyTestSupport
import Foundation
import MetalUI
import MetalUITesting
import Testing

/// The frame guards with a server that offers hover, symbols and references, and with the palette open, closed and idle.
@MainActor
@Suite struct IntelGuardTests {
    private typealias Perf = CodeModePerformanceTests
    /// The hover's hidden text-anchored popover (a known MetalUI gap, see `HoverGuardTests`); never raise it.
    private static let knownPopoverGap = 0

    private static func script(hits: Int = 3, root: String = "") -> String {
        let symbol = #"{"name":"login","kind":12,"range":{"start":{"line":0,"character":0},"end":{"line":0,"character":5}},"selectionRange":{"start":{"line":0,"character":0},"end":{"line":0,"character":5}}}"#
        let refs = (0..<hits).map { #"{"uri":"file://\#(root)/other.swift","range":{"start":{"line":\#($0),"character":0},"end":{"line":\#($0),"character":1}}}"# }
        return IntelRig.script(
            caps: #""hoverProvider":true,"documentSymbolProvider":true,"referencesProvider":true,"documentFormattingProvider":true,"documentRangeFormattingProvider":true"#,
            extra: #","replies":{"textDocument/hover":[{"result":{"contents":{"kind":"markdown","value":"**docs**"}}}],"textDocument/formatting":[{"result":[{"range":{"start":{"line":0,"character":0},"end":{"line":0,"character":0}},"newText":"x"}]}],"textDocument/documentSymbol":[{"result":[\#(symbol)]}],"textDocument/references":[{"result":[\#(refs.joined(separator: ","))]}]}"#)
    }

    private func guardTyping(_ layout: Perf.Layout, steady: Int, carets: Int = 1) async throws {
        let perf = Perf()
        let (intel, window, id) = try await IntelRig.guardRig(layout: layout, script: Self.script())
        try await window.runUntil { intel.coordinator.features(for: "login.swift").documentSymbol }
        let t = try await perf.typing(window, intel.rig, codeViewID: id, names: Perf.watched, carets: carets)
        #expect(t.documentGrew)
        #expect(t.perFrame.allSatisfy { $0 <= steady + Self.knownPopoverGap }, "per-frame element requests \(t.perFrame)")
        #expect(t.requests <= (steady + Self.knownPopoverGap) * 20, "element requests \(t.requests)")
        #expect(t.reruns["CodePanel"] == 0, "CodePanel re-ran \(t.reruns["CodePanel"] ?? -1) times while typing")
        for n in ["CodeIslandRow", "EditorAreaView", "TitleIsland", "ChatView", "AlloyScreen"] {
            #expect(t.reruns[n] == 0, "\(layout) \(n) re-ran \(t.reruns[n] ?? -1) times")
        }
        withExtendedLifetime((intel, window)) {}
    }

    @Test func typingWithTheFullCapabilitySetHoldsTheSteadyFrameGuardChat() async throws {
        try await guardTyping(.chat, steady: ViewRerunTests.steadyFrameRequests)
    }
    @Test func typingWithThreeCaretsAndTheFullCapabilitySetHoldsTheGuardChat() async throws {
        try await guardTyping(.chat, steady: ViewRerunTests.steadyFrameRequests, carets: 3)
    }
    @Test func typingWithThreeCaretsAndTheFullCapabilitySetHoldsTheGuardCode1() async throws { try await guardTyping(.code1, steady: Perf.steadyCode1, carets: 3) }
    @Test func typingWithTheFullCapabilitySetHoldsTheSteadyFrameGuardCode1() async throws { try await guardTyping(.code1, steady: Perf.steadyCode1) }
    @Test func typingWithTheFullCapabilitySetHoldsTheSteadyFrameGuardCode2() async throws { try await guardTyping(.code2, steady: Perf.steadyCode2) }
    @Test func typingWithTheFullCapabilitySetHoldsTheSteadyFrameGuardCode3() async throws { try await guardTyping(.code3, steady: Perf.steadyCode3) }

    /// Idle frames after `frames` ticks: element requests and body reruns by name.
    private func idle(_ window: TestWindow, frames: Int, perf: Perf) async -> (requests: Int, reruns: [String: Int]) {
        window.resetFrameWork()
        var reruns: [String: Int] = [:]
        for _ in 0..<frames {
            for (k, v) in perf.allProbes({ window.tick() }) { reruns[k, default: 0] += v }
            await Task.yield()
        }
        return (window.frameWork.reduce(0) { $0 + $1.elementRequests }, reruns)
    }

    private func openPalette(_ window: TestWindow, key: () -> Void, id: String) async throws {
        key()
        try await window.runUntil { (try? window.element(identifier: id)) != nil }
        for _ in 0..<10 { window.tick(); await Task.yield() }
    }

    /// A palette opened and closed again leaves the idle cost where it was.
    @Test func aPaletteOpenedAndClosedReturnsToTheSameIdleCost() async throws {
        let perf = Perf()
        let (intel, window, id) = try await IntelRig.guardRig(layout: .chat, script: Self.script())
        try await window.runUntil { intel.coordinator.features(for: "login.swift").documentSymbol }
        try window.click(window.element(identifier: id))
        for _ in 0..<15 { window.tick(); await Task.yield() }
        let before = await idle(window, frames: 15, perf: perf)
        try await openPalette(window, key: { window.typeKey("o", modifierFlags: [.command, .shift]) }, id: "symbols-palette")
        window.typeKey(.escape)
        try await window.runUntil { (try? window.element(identifier: "symbols-palette")) == nil }
        try window.click(window.element(identifier: id))
        for _ in 0..<15 { window.tick(); await Task.yield() }
        let after = await idle(window, frames: 15, perf: perf)
        print("INTELGUARD idle before=\(before.requests) after=\(after.requests)")
        #expect(after.requests == before.requests, "idle requests \(after.requests) != \(before.requests) before opening")
        #expect(after.reruns.isEmpty, "idle ticks re-ran \(after.reruns)")
        withExtendedLifetime(intel) {}
    }

    /// An open, idle palette re-runs no sibling body.
    @Test func anOpenIdlePaletteReRunsNoSibling() async throws {
        let perf = Perf()
        let (intel, window, id) = try await IntelRig.guardRig(layout: .chat, script: Self.script())
        try await window.runUntil { intel.coordinator.features(for: "login.swift").documentSymbol }
        try window.click(window.element(identifier: id))
        for _ in 0..<5 { window.tick(); await Task.yield() }
        try await openPalette(window, key: { window.typeKey("o", modifierFlags: [.command, .shift]) }, id: "symbols-palette")
        let open = await idle(window, frames: 20, perf: perf)
        print("INTELGUARD open idle requests=\(open.requests) reruns=\(open.reruns)")
        for n in ["CodeIslandRow", "EditorAreaView", "ChatView", "TitleIsland"] { #expect(open.reruns[n] ?? 0 == 0, "\(n) re-ran \(open.reruns[n] ?? 0) times") }
        withExtendedLifetime(intel) {}
    }

    /// A references palette over thousands of hits costs the same per idle frame as one over three: it shows 50 rows at most.
    @Test func aHugeReferencesPaletteIdlesLikeASmallOne() async throws {
        let perf = Perf()
        func idleCost(hits: Int) async throws -> Int {
            let (intel, window, id) = try await IntelRig.guardRig(layout: .chat, scriptFor: { Self.script(hits: hits, root: $0.root.path) })
            try await window.runUntil { intel.coordinator.features(for: "login.swift").references }
            try window.click(window.element(identifier: id))
            for _ in 0..<5 { window.tick(); await Task.yield() }
            try await openPalette(window, key: { window.typeKey(FilePanelView.f12, modifierFlags: .shift) }, id: "references-palette")
            let cost = await idle(window, frames: 20, perf: perf)
            withExtendedLifetime(intel) {}
            return cost.requests
        }
        _ = try await idleCost(hits: 3)
        let small = try await idleCost(hits: 60)
        let huge = try await idleCost(hits: 4_000)
        print("INTELGUARD references idle small=\(small) huge=\(huge)")
        #expect(huge <= small, "idle requests \(huge) > \(small)")
    }

    /// A deliberate save with the switch off asks nothing and leaves the idle cost where it was.
    @Test func formatOnSaveWithTheSwitchOffCostsNothingAfterwards() async throws {
        let perf = Perf()
        let (intel, window, id) = try await IntelRig.guardRig(layout: .chat, script: Self.script())
        try await window.runUntil { intel.coordinator.features(for: "login.swift").formatting }
        try window.click(window.element(identifier: id))
        for _ in 0..<15 { window.tick(); await Task.yield() }
        let before = await idle(window, frames: 15, perf: perf)
        let doc = try #require(intel.rig.workspace.document("login.swift"))
        _ = doc.buffer.replace(0..<0, with: " ")
        try await intel.rig.workspace.save("login.swift", format: true)
        for _ in 0..<15 { window.tick(); await Task.yield() }
        let after = await idle(window, frames: 15, perf: perf)
        print("INTELGUARD format-on-save off idle before=\(before.requests) after=\(after.requests)")
        #expect(!intel.methods().contains("textDocument/formatting"))
        #expect(after.requests <= before.requests, "idle requests \(after.requests) > \(before.requests)")
        #expect(after.reruns.isEmpty, "idle ticks re-ran \(after.reruns)")
        withExtendedLifetime(intel) {}
    }

    /// A document formatted by command idles at the cost it had before.
    @Test func aFormattedDocumentIdlesLikeBefore() async throws {
        let perf = Perf()
        let (intel, window, id) = try await IntelRig.guardRig(layout: .chat, script: Self.script())
        try await window.runUntil { intel.coordinator.features(for: "login.swift").formatting }
        try window.click(window.element(identifier: id))
        for _ in 0..<15 { window.tick(); await Task.yield() }
        let before = await idle(window, frames: 15, perf: perf)
        let doc = try #require(intel.rig.workspace.document("login.swift"))
        let size = doc.buffer.utf8Count
        intel.rig.workspace.intelHooks.run[.formatDocument]?()
        try await window.runUntil { doc.buffer.utf8Count == size + 1 }
        for _ in 0..<15 { window.tick(); await Task.yield() }
        let after = await idle(window, frames: 15, perf: perf)
        print("INTELGUARD formatted idle before=\(before.requests) after=\(after.requests)")
        #expect(after.requests <= before.requests, "idle requests \(after.requests) > \(before.requests)")
        #expect(after.reruns.isEmpty, "idle ticks re-ran \(after.reruns)")
        withExtendedLifetime(intel) {}
    }
}
