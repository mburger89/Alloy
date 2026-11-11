@testable import AlloyCore
import AlloyTestSupport
import Foundation
import Testing

@MainActor
private final class FakeWorkshop: ThemeWorkshop {
    var slotCatalog: [ThemeSlotInfo] = [
        ThemeSlotInfo(name: "background", purpose: "The window background."),
        ThemeSlotInfo(name: "mutedInk", purpose: "Quiet text."),
        ThemeSlotInfo(name: "chatFill", purpose: "The chat pane."),
    ]
    var library: ThemeLibrary
    var shownTheme: ResolvedTheme?
    var previews: [(draft: ThemeFile, resolved: ResolvedTheme, session: UUID)] = []
    var saves: [(saved: SavedTheme, file: ThemeFile, session: UUID)] = []
    var ended: [UUID] = []

    init(library: ThemeLibrary) {
        self.library = library
        shownTheme = library.resolve("alloy-dark")
    }

    func preview(_ draft: ThemeFile, resolved: ResolvedTheme, session: UUID) { previews.append((draft, resolved, session)) }
    func didSave(_ saved: SavedTheme, file: ThemeFile, session: UUID) async { saves.append((saved, file, session)) }
    func themeSessionEnded(_ session: UUID) { ended.append(session) }
}

@MainActor
@Suite(.timeLimit(.minutes(1))) final class ThemeToolsTests {
    private var dirs: [URL] = []
    deinit { for d in dirs { try? FileManager.default.removeItem(at: d) } }

    private let session = UUID()
    private var caller: MCPCaller { MCPCaller(sessionID: session, scopes: [.theme]) }

    private func makeSupport() -> URL {
        let u = FileManager.default.temporaryDirectory.appendingPathComponent("alloy-themetools-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        dirs.append(u)
        return u
    }

    @MainActor private struct Rig {
        let ws: Workspace
        let shop: FakeWorkshop
        let support: URL
        var tools: [String: MCPTool] { Dictionary(uniqueKeysWithValues: ws.themeTools.map { ($0.name, $0) }) }
    }

    private func rig(withWorkshop: Bool = true, user: [ThemeEntry] = []) -> Rig {
        let support = makeSupport()
        let root = makeSupport()
        let ws = Workspace(projectRoot: root, appSupport: support, settings: AlloySettings(),
                           locate: { _ in URL(fileURLWithPath: "/fake/claude") }, makeTransport: { _ in ScriptedTransport() })
        let shop = FakeWorkshop(library: ThemeLibrary(builtIns: BuiltInThemes.all, user: user))
        if withWorkshop { ws.themeWorkshop = shop }
        return Rig(ws: ws, shop: shop, support: support)
    }

    private func call(_ r: Rig, _ tool: String, _ args: [String: JSONValue]) async -> MCPToolResult {
        await r.tools[tool]!.call(.object(args), caller: caller)
    }

    private func object(_ result: MCPToolResult) throws -> JSONValue {
        try #require(JSONValue.parse(Data(result.text.utf8)))
    }

    private func draft(_ extra: [String: JSONValue] = [:]) -> JSONValue {
        var o: [String: JSONValue] = ["name": .string("Warm"), "appearance": .string("dark"), "base": .string("dracula"),
                                      "colors": .object(["accent": .string("#FF8800")])]
        for (k, v) in extra { o[k] = v }
        return .object(o)
    }

    private func folderState(_ support: URL) -> [String] {
        let dir = ThemeLibrary.userDirectory(appSupport: support)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        return names.sorted()
    }

    @Test func slotsListsCatalogWithShownValues() async throws {
        let r = rig()
        let result = await call(r, "theme_slots", [:])
        #expect(!result.isError)
        let o = try object(result)
        #expect(o["theme"]?.stringValue == "alloy-dark")
        #expect(o["appearance"]?.stringValue == "dark")
        let slots = try #require(o["slots"]?.arrayValue)
        #expect(slots.count == 3)
        #expect(slots[0]["name"]?.stringValue == "background")
        #expect(slots[0]["purpose"]?.stringValue == "The window background.")
        let shown = try #require(r.shop.shownTheme)
        #expect(slots[0]["value"]?.stringValue == shown.colors["background"]?.hex)
        #expect(slots[2]["value"]?.stringValue == shown.colors["chatFill"]?.hex)
        #expect(o["sessionColors"]?.arrayValue?.count == shown.sessionColors.count)
        #expect(o["format"]?.stringValue?.isEmpty == false)
    }

    @Test func slotsWithNothingShownReturnsNullThemeAndSlotList() async throws {
        let r = rig()
        r.shop.shownTheme = nil
        let o = try object(await call(r, "theme_slots", [:]))
        #expect(o["theme"] == .null)
        #expect(o["appearance"] == .null)
        #expect(o["slots"]?.arrayValue?.count == 3)
        #expect(o["slots"]?.arrayValue?.first?["value"] == .null)
    }

    @Test func readFindsByIdAndName() async throws {
        let userFile = ThemeFile(name: "Mine", appearance: .light, colors: ["accent": ThemeRGBA(hex: "#112233")!])
        let r = rig(user: [ThemeEntry(id: "user/mine-stem", file: userFile, isBuiltIn: false)])
        for name in ["dracula", "Dracula", "DRACULA", "user/mine-stem", "mine"] {
            let result = await call(r, "theme_read", ["name": .string(name)])
            #expect(!result.isError, "\(name)")
            let o = try object(result)
            #expect(o["file"]?["name"] != nil)
            #expect(o["resolved"]?["background"]?.stringValue?.hasPrefix("#") == true)
        }
        let d = try object(await call(r, "theme_read", ["name": .string("Dracula")]))
        #expect(d["id"]?.stringValue == "dracula")
        #expect(d["builtIn"]?.boolValue == true)
        let missing = await call(r, "theme_read", ["name": .string("nope")])
        #expect(missing.isError)
        #expect(missing.text.hasPrefix("No theme named \"nope\". Themes: "))
        #expect(missing.text.contains("alloy-dark"))
        #expect(missing.text.contains("user/mine-stem"))
    }

    @Test func checkReportsFindingsAndIgnoredSlots() async throws {
        let r = rig()
        let bad = draft(["base": .string("alloy-dark"),
                         "colors": .object(["notASlot": .string("#123456"), "mutedInk": .string("#16181D")])])
        let result = await call(r, "theme_check", ["theme": bad])
        #expect(!result.isError)
        let o = try object(result)
        #expect(o["ignoredSlots"]?.arrayValue == [.string("notASlot")])
        let findings = try #require(o["findings"]?.arrayValue)
        #expect(!findings.isEmpty)
        #expect(findings.contains { $0["pair"]?.stringValue == "mutedInk on background" })
        #expect(findings.allSatisfy { $0["pair"]?.stringValue?.hasPrefix("mutedInk") == true })
        #expect(o["notes"]?.arrayValue != nil)
        #expect(r.shop.previews.isEmpty)
    }

    @Test func previewCallsWorkshopWithResolvedDraft() async throws {
        let r = rig()
        let result = await call(r, "theme_preview", ["theme": draft()])
        #expect(!result.isError)
        let o = try object(result)
        #expect(o["previewing"]?.stringValue == "Warm")
        #expect(r.shop.previews.count == 1)
        let p = try #require(r.shop.previews.first)
        #expect(p.session == session)
        #expect(p.draft.name == "Warm")
        let dracula = try #require(r.shop.library.resolve("dracula"))
        #expect(p.resolved.colors["chatFill"] == dracula.colors["chatFill"])
        #expect(p.resolved.colors["accent"]?.hex == "#FF8800")
        #expect(p.draft.author == "Made in an Alloy theme session")
        // The same draft as a JSON string works too.
        let data = try JSONEncoder().encode(draft())
        let viaString = await call(r, "theme_preview", ["theme": .string(String(decoding: data, as: UTF8.self))])
        #expect(!viaString.isError)
        #expect(r.shop.previews.count == 2)
    }

    @Test func saveWritesFileAndNeverActivates() async throws {
        let r = rig()
        var stored = AlloySettings()
        stored.theme = "alloy-light"
        try stored.save(appSupport: r.support)
        let settings = AlloySettings.url(appSupport: r.support)
        let before = try Data(contentsOf: settings)
        #expect(!before.isEmpty)
        let result = await call(r, "theme_save", ["name": .string("Warm Paper"), "theme": draft()])
        #expect(!result.isError, "\(result.text)")
        let o = try object(result)
        #expect(o["saved"]?.stringValue == "user/warm-paper")
        #expect(o["name"]?.stringValue == "Warm Paper")
        #expect(o["renamed"]?.boolValue == false)
        #expect(o["active"]?.boolValue == false)
        #expect(o["findings"]?.arrayValue != nil)
        #expect(folderState(r.support) == ["warm-paper.json"])
        let onDisk = try ThemeFile.parse(Data(contentsOf: ThemeLibrary.userDirectory(appSupport: r.support)
            .appendingPathComponent("warm-paper.json")))
        #expect(onDisk.name == "Warm Paper")
        #expect(r.shop.saves.count == 1)
        #expect(r.shop.saves[0].saved.id == "user/warm-paper")
        #expect(r.shop.saves[0].session == session)
        #expect(try Data(contentsOf: settings) == before)
    }

    @Test func badDraftsAreRefusedWithoutSideEffects() async throws {
        let r = rig()
        let huge = String(repeating: "a", count: ThemeFile.maxBytes + 10)
        let cases: [(String, JSONValue)] = [
            ("number", .number(5)),
            ("brace", .string("{")),
            ("huge", .string("{\"name\":\"x\",\"appearance\":\"dark\",\"pad\":\"\(huge)\"}")),
            ("shortHex", draft(["colors": .object(["accent": .string("#FFF")])])),
            ("fiveSession", draft(["sessionColors": .array((0..<5).map { _ in .string("#112233") })])),
            ("dim", draft(["appearance": .string("dim")])),
        ]
        for (label, theme) in cases {
            for tool in ["theme_preview", "theme_check", "theme_save"] {
                var args: [String: JSONValue] = ["theme": theme]
                if tool == "theme_save" { args["name"] = .string("X") }
                let result = await call(r, tool, args)
                #expect(result.isError, "\(label) \(tool)")
            }
        }
        #expect(r.shop.previews.isEmpty)
        #expect(r.shop.saves.isEmpty)
        #expect(folderState(r.support).isEmpty)
        let fallback = await call(r, "theme_check", ["theme": draft(["base": .string("nope")])])
        #expect(!fallback.isError)
        let notes = try #require(try object(fallback)["notes"]?.arrayValue)
        #expect(notes.contains { $0.stringValue?.contains("Unknown base") == true })
    }

    @Test func noWorkshopIsAnError() async throws {
        let r = rig(withWorkshop: false)
        let args: [String: [String: JSONValue]] = [
            "theme_slots": [:], "theme_read": ["name": .string("dracula")], "theme_check": ["theme": draft()],
            "theme_preview": ["theme": draft()], "theme_save": ["name": .string("X"), "theme": draft()],
        ]
        for (tool, a) in args {
            let result = await call(r, tool, a)
            #expect(result.isError, "\(tool)")
            #expect(result.text == "Alloy's theme tools are not available right now.", "\(tool)")
        }
        #expect(folderState(r.support).isEmpty)
    }

    @Test func everyThemeToolIsThemeScoped() throws {
        let r = rig()
        let names = r.ws.themeTools.map { "mcp__alloy__" + $0.name }
        #expect(Set(names) == Set(Guidance.themeToolNames))
        #expect(r.ws.themeTools.count == 5)
        #expect(r.ws.themeTools.allSatisfy { $0.scope == .theme })
        let save = try #require(r.ws.themeTools.first { $0.name == "theme_save" })
        #expect(save.description.contains("Keep"))
    }
}
