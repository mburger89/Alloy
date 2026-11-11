import AlloyCore
@testable import AlloyKit
import AlloyTestSupport
import Foundation
import MetalUI
import MetalUITesting
import Testing

@MainActor
@Suite struct ThemePreviewTests {
    @MainActor private struct Probe {
        let window: TestWindow
        let box = ResolvedBox()
        init(_ colors: [Color]) throws {
            let box = self.box
            window = try TestWindow(size: Size(width: Pixels(100), height: Pixels(100))) { ColorProbe(colors: colors, box: box) }
            window.tick()
        }
        func resolved() -> [Color.Resolved] {
            window.window.setNeedsRedraw()
            window.tick(); window.tick()
            return box.colors
        }
    }

    private func hex(_ value: String) -> Color { Color(ThemeRGBA(hex: value)!.hsla) }
    private func rgba(_ value: String) -> ThemeRGBA { ThemeRGBA(hex: value)! }

    private func same(_ a: Color.Resolved, _ b: Color.Resolved) -> Bool {
        abs(a.red - b.red) < 0.01 && abs(a.green - b.green) < 0.01 && abs(a.blue - b.blue) < 0.01
    }

    private func support(_ rig: Rig) -> URL { rig.root.appendingPathComponent("support") }
    private func themesDirectory(_ rig: Rig) -> URL { ThemeLibrary.userDirectory(appSupport: support(rig)) }
    private func listing(_ rig: Rig) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: themesDirectory(rig).path)) ?? []).sorted()
    }
    private func settingsBytes(_ rig: Rig) -> Data? {
        try? Data(contentsOf: support(rig).appendingPathComponent("Alloy/settings.json"))
    }

    private func waitFor(_ what: String, _ condition: () -> Bool) async {
        for _ in 0..<400 where !condition() { try? await Task.sleep(for: .milliseconds(10)) }
        #expect(condition(), "\(what)")
    }

    private func warmDraft(name: String = "Warm", appearance: ThemeAppearance = .light, base: String = "solarized-light",
                           chat: String = "#FFF8E7") -> ThemeFile {
        ThemeFile(name: name, appearance: appearance, base: base, colors: ["chatFill": rgba(chat)])
    }

    private func start(_ rig: Rig, _ probe: Probe, watcher: FileChangeSource? = nil) -> ThemeController {
        ThemeController(workspace: rig.workspace, host: probe.window.window, watcher: watcher)
    }

    private func startPreview(_ c: ThemeController, _ draft: ThemeFile, session: UUID = UUID()) -> UUID {
        c.preview(draft, resolved: c.library.resolve(draft: draft).theme, session: session)
        return session
    }

    @Test func previewRepaintsWithoutTouchingSettings() throws {
        let rig = Rig()
        try rig.workspace.updateSettings(AlloySettings())
        let probe = try Probe([.chatFill, hex("#FFF8E7")])
        let c = start(rig, probe)
        let before = settingsBytes(rig), folder = listing(rig)
        _ = startPreview(c, warmDraft())
        let r = probe.resolved()
        #expect(same(r[0], r[1]), "chatFill is the draft's")
        #expect(probe.window.window.preferredColorScheme == .light)
        #expect(settingsBytes(rig) == before)
        #expect(listing(rig) == folder)
        #expect(c.preview?.name == "Warm")
        #expect(c.shownTheme == c.preview?.resolved)
    }

    @Test func discardRestoresTheUsersTheme() throws {
        let rig = Rig()
        let probe = try Probe([.chatFill, hex("#282A36")])
        let c = start(rig, probe)
        _ = startPreview(c, warmDraft())
        c.discardPreview()
        let r = probe.resolved()
        #expect(same(r[0], r[1]), "Dracula's chatFill")
        #expect(probe.window.window.preferredColorScheme == .dark)
        #expect(c.preview == nil)
    }

    @Test func sessionEndRestoresTheUsersTheme() throws {
        let rig = Rig()
        let probe = try Probe([.chatFill, hex("#282A36")])
        let c = start(rig, probe)
        let session = startPreview(c, warmDraft())
        c.themeSessionEnded(UUID())
        #expect(c.preview != nil, "another session's end leaves the preview")
        c.themeSessionEnded(session)
        let r = probe.resolved()
        #expect(same(r[0], r[1]))
        #expect(c.preview == nil)
        #expect(probe.window.window.preferredColorScheme == .dark)
    }

    @Test func sessionEndTwiceDoesNothingTheSecondTime() throws {
        let rig = Rig()
        let probe = try Probe([.chatFill])
        let c = start(rig, probe)
        let first = startPreview(c, warmDraft())
        c.themeSessionEnded(first)
        c.themeSessionEnded(first)
        #expect(c.preview == nil)
        // A newer preview from another session must survive a late second end of the first session.
        let second = startPreview(c, warmDraft(name: "Second"))
        c.themeSessionEnded(first)
        #expect(c.preview?.session == second)
        c.themeSessionEnded(second)
        c.themeSessionEnded(second)
        #expect(c.preview == nil)
    }

    @Test func reloadDuringPreviewKeepsPreview() async throws {
        let rig = Rig()
        let dir = themesDirectory(rig)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("mine.json")
        func mine(_ accent: String) -> String { #"{"name":"Mine","appearance":"dark","base":"dracula","colors":{"accent":"\#(accent)"}}"# }
        try mine("#FF0000").write(to: url, atomically: true, encoding: .utf8)
        try rig.workspace.updateSettings(AlloySettings(theme: "user/mine"))
        let probe = try Probe([Color(ColorToken.accent), hex("#0000FF"), hex("#00FF00")])
        let watcher = ScriptedChangeSource()
        let c = start(rig, probe, watcher: watcher)
        defer { c.stop() }
        var draft = warmDraft()
        draft.colors["accent"] = rgba("#0000FF")
        _ = startPreview(c, draft)
        try mine("#00FF00").write(to: url, atomically: true, encoding: .utf8)
        let before = c.reloadCount
        watcher.send([url.path])
        await waitFor("reloaded") { c.reloadCount > before && c.library.resolve("user/mine")?.colors["accent"] == self.rgba("#00FF00") }
        var r = probe.resolved()
        #expect(same(r[0], r[1]), "the draft is still shown")
        c.discardPreview()
        r = probe.resolved()
        #expect(same(r[0], r[2]), "the reloaded user theme shows")
    }

    @Test func keepSavesUnsavedDraftAndActivates() async throws {
        let rig = Rig()
        let probe = try Probe([.chatFill])
        let c = start(rig, probe)
        let session = startPreview(c, warmDraft())
        try await c.keepPreview()
        #expect(listing(rig) == ["warm.json"])
        #expect(c.currentSettings.theme == "user/warm")
        #expect(c.preview == nil)
        let owners = try String(contentsOf: support(rig).appendingPathComponent("Alloy/theme-owners.json"), encoding: .utf8)
        #expect(owners.contains(session.uuidString))
        #expect(c.library.entry("user/warm") != nil)
    }

    @Test func keepAfterSaveDoesNotSaveTwice() async throws {
        let rig = Rig()
        let probe = try Probe([.chatFill])
        let c = start(rig, probe)
        let draft = warmDraft()
        let session = startPreview(c, draft)
        let saved = try ThemeStore(appSupport: support(rig)).save(draft, name: "Warm", session: session, builtIns: BuiltInThemes.all)
        var file = draft; file.name = saved.name
        await c.didSave(saved, file: file, session: session)
        #expect(c.preview?.savedID == saved.id)
        try await c.keepPreview()
        #expect(listing(rig) == ["warm.json"])
        #expect(c.currentSettings.theme == saved.id)
    }

    @Test func didSaveFromAnotherSessionOrDifferentFileDoesNotMarkSaved() async throws {
        let rig = Rig()
        let probe = try Probe([.chatFill])
        let c = start(rig, probe)
        let draft = warmDraft()
        let session = startPreview(c, draft)
        let saved = try ThemeStore(appSupport: support(rig)).save(draft, name: "Warm", session: session, builtIns: BuiltInThemes.all)
        await c.didSave(saved, file: draft, session: UUID())
        #expect(c.preview?.savedID == nil)
        var other = draft; other.colors["chatFill"] = rgba("#000000")
        await c.didSave(saved, file: other, session: session)
        #expect(c.preview?.savedID == nil)
    }

    @Test func keepInMatchSystemSetsTheAppearanceSlot() async throws {
        let rig = Rig()
        let probe = try Probe([.chatFill])
        let c = start(rig, probe)
        try c.choose(mode: .matchSystem, light: "alloy-light", dark: "one-dark")
        _ = startPreview(c, warmDraft())
        try await c.keepPreview()
        #expect(c.currentSettings.lightTheme == "user/warm")
        #expect(c.currentSettings.darkTheme == "one-dark")
        #expect(c.currentSettings.themeMode == .matchSystem)
    }

    @Test func findingsAskBeforeActivating() async throws {
        let rig = Rig()
        let probe = try Probe([.chatFill])
        let c = start(rig, probe)
        // Grey text on a grey background: hard to read in several pairs.
        let bad = ThemeFile(name: "Murky", appearance: .dark, base: "dracula",
                            colors: ["textPrimary": rgba("#2A2C38"), "mutedInk": rgba("#2A2C38")])
        let saved = try ThemeStore(appSupport: support(rig)).save(bad, name: "Murky", session: UUID(), builtIns: BuiltInThemes.all)
        await c.reload()
        let expected = ThemeContrast.findings(try #require(c.library.resolve(saved.id))).count
        #expect(expected > 0)
        let before = settingsBytes(rig)
        try c.request(theme: saved.id)
        #expect(c.pendingActivation == PendingActivation(themeID: saved.id, findingCount: expected, slot: .single))
        #expect(settingsBytes(rig) == before)
        #expect(c.currentSettings.theme == "dracula")
        c.cancelActivation()
        #expect(c.pendingActivation == nil && c.currentSettings.theme == "dracula")
        try c.request(theme: saved.id)
        try c.confirmActivation()
        #expect(c.pendingActivation == nil)
        #expect(c.currentSettings.theme == saved.id)
    }

    @Test func keepWithFindingsLeavesThemePendingAndClearsPreview() async throws {
        let rig = Rig()
        let probe = try Probe([.chatFill])
        let c = start(rig, probe)
        let bad = ThemeFile(name: "Murky", appearance: .dark, base: "dracula",
                            colors: ["textPrimary": rgba("#2A2C38"), "mutedInk": rgba("#2A2C38")])
        _ = startPreview(c, bad)
        try await c.keepPreview()
        #expect(c.preview == nil)
        #expect(c.pendingActivation?.themeID == "user/murky")
        #expect(c.currentSettings.theme == "dracula")
    }

    @Test func builtInsActivateWithoutWarning() throws {
        let rig = Rig()
        let probe = try Probe([.chatFill])
        let c = start(rig, probe)
        try c.request(theme: "one-dark")
        #expect(c.pendingActivation == nil)
        #expect(c.currentSettings.theme == "one-dark")
    }

    @Test func bindingRegistersTheWorkshop() throws {
        let rig = Rig()
        let probe = try Probe([.chatFill])
        let c = start(rig, probe)
        #expect(rig.workspace.themeWorkshop === c)
        #expect(c.slotCatalog.map(\.name) == ThemeSlots.all.map(\.name))
    }

    @Test func keepSavesAgainWhenTheSavedFileNoLongerMatches() async throws {
        let rig = Rig()
        let probe = try Probe([.chatFill])
        let c = start(rig, probe)
        let draft = warmDraft()
        let session = startPreview(c, draft)
        let store = ThemeStore(appSupport: support(rig))
        let saved = try store.save(draft, name: "Warm", session: session, builtIns: BuiltInThemes.all)
        await c.didSave(saved, file: draft, session: session)
        #expect(c.preview?.savedID == saved.id)
        // The session saves something else over the same file.
        let other = warmDraft(chat: "#000000")
        let again = try store.save(other, name: "Warm", session: session, builtIns: BuiltInThemes.all)
        #expect(again.id == saved.id)
        await c.didSave(again, file: other, session: session)
        #expect(c.preview?.savedID == nil, "same id, different content clears it")
        try await c.keepPreview()
        let kept = try #require(c.library.entry(c.currentSettings.theme))
        #expect(kept.file.colors["chatFill"] == rgba("#FFF8E7"), "the previewed draft was saved again")
    }

    @Test func keepIgnoresSavedIDWhenFileWasHandEdited() async throws {
        let rig = Rig()
        let probe = try Probe([.chatFill])
        let c = start(rig, probe)
        let draft = warmDraft()
        let session = startPreview(c, draft)
        let saved = try ThemeStore(appSupport: support(rig)).save(draft, name: "Warm", session: session, builtIns: BuiltInThemes.all)
        await c.didSave(saved, file: draft, session: session)
        var edited = draft; edited.colors["chatFill"] = rgba("#111111")
        try edited.encoded().write(to: saved.url)
        await c.reload()
        try await c.keepPreview()
        let kept = try #require(c.library.entry(c.currentSettings.theme))
        #expect(kept.file.colors["chatFill"] == rgba("#FFF8E7"))
        #expect(listing(rig).count == 2, "the hand-edited file is the user's, so a new file was written")
    }

    @Test func keepLeavesANewerPreviewFromTheSameSession() async throws {
        let rig = Rig()
        let probe = try Probe([.chatFill])
        let c = start(rig, probe)
        let session = startPreview(c, warmDraft())
        let newer = warmDraft(name: "Newer", chat: "#ABCDEF")
        // The newer preview lands after Keep's save and before it finishes: no scheduling involved.
        c.afterKeepSave = { c.preview(newer, resolved: c.library.resolve(draft: newer).theme, session: session) }
        try await c.keepPreview()
        #expect(c.preview?.name == "Newer")
    }

    @Test func shownThemeFallsBackLikeApply() throws {
        let rig = Rig()
        try rig.workspace.updateSettings(AlloySettings(theme: "user/gone"))
        let probe = try Probe([.chatFill])
        let c = start(rig, probe)
        #expect(c.shownTheme?.id == "dracula")
    }

    @Test func discardInMatchSystemClearsTheForcedScheme() throws {
        let rig = Rig()
        let probe = try Probe([.chatFill])
        let c = start(rig, probe)
        try c.choose(mode: .matchSystem, light: "alloy-light", dark: "one-dark")
        _ = startPreview(c, warmDraft())
        #expect(probe.window.window.preferredColorScheme == .light)
        c.discardPreview()
        #expect(probe.window.window.preferredColorScheme == nil)
    }
}
