import AlloyCore
@testable import AlloyKit
import AlloyTestSupport
import Foundation
import MetalUI
import MetalUITesting
import Testing

@MainActor
@Suite struct SettingsThemeTests {
    private final class Holder { var controller: ThemeController? }

    private struct Setup {
        let rig: Rig
        let window: TestWindow
        let controller: ThemeController
        let watcher: ScriptedChangeSource
        let opened = OpenedBox()
        /// Glyph origins on screen before Settings opened: text of the chat underneath, which the panel covers.
        let underneath: Set<[Float]>
    }

    private final class OpenedBox { var urls: [URL] = [] }

    private func setup(width: Pixels = Pixels(1200), settings: AlloySettings? = nil, prepare: (Rig) throws -> Void = { _ in }) async throws -> Setup {
        let rig = Rig()
        try prepare(rig)
        if let settings { try rig.workspace.updateSettings(settings) }
        let holder = Holder()
        let window = try TestWindow(size: Size(width: width, height: Pixels(800))) {
            rootView(workspace: rig.workspace, themes: holder.controller)
        }
        window.installAlloyMenu(rig.workspace)
        let watcher = ScriptedChangeSource()
        let controller = ThemeController(workspace: rig.workspace, host: window.window, watcher: watcher)
        holder.controller = controller
        window.tick(); window.tick()
        let underneath = Set(window.scene.glyphs.map { [$0.bounds.origin.x, $0.bounds.origin.y] })
        let s = Setup(rig: rig, window: window, controller: controller, watcher: watcher, underneath: underneath)
        try window.openSettingsFromMenu()
        try await window.runUntil { (try? window.element(identifier: "settings-theme-section")) != nil }
        return s
    }

    private func rowIDs(_ window: TestWindow, prefix: String) -> [String] {
        ((try? window.elements(where: { ($0.identifier ?? "").hasPrefix(prefix) })) ?? []).compactMap(\.identifier)
    }

    private func themesDirectory(_ rig: Rig) -> URL {
        ThemeLibrary.userDirectory(appSupport: rig.root.appendingPathComponent("support"))
    }

    private func waitFor(_ what: String, _ condition: () -> Bool) async {
        for _ in 0..<400 where !condition() { try? await Task.sleep(for: .milliseconds(10)) }
        #expect(condition(), "\(what)")
    }

    @Test func sectionShowsAllThemesWithDraculaChecked() async throws {
        let t = try await setup()
        defer { t.controller.stop() }
        let ids = rowIDs(t.window, prefix: "theme-row-")
        #expect(ids.count == 6, "\(ids)")
        for entry in t.controller.library.all {
            let row = try t.window.element(identifier: "theme-row-\(entry.id)")
            #expect((row.label ?? "").contains(entry.file.name))
            #expect(row.isSelected == (entry.id == "dracula"), "\(entry.id)")
        }
        _ = try t.window.element(identifier: "settings-theme-mode")
        _ = try t.window.element(identifier: "settings-theme-list")
    }

    @Test func clickingARowAppliesIt() async throws {
        let t = try await setup()
        defer { t.controller.stop() }
        let oneDark = ThemeApplier.theme(for: try #require(t.controller.library.resolve("one-dark")))
        #expect(t.window.window.darkTheme != oneDark)
        try t.window.click(t.window.element(identifier: "theme-row-one-dark"))
        try await t.window.runUntil { t.window.window.darkTheme == oneDark }
        let text = try String(contentsOf: t.rig.root.appendingPathComponent("support/Alloy/settings.json"), encoding: .utf8)
        #expect(text.contains("\"theme\":\"one-dark\"") || text.contains("\"theme\" : \"one-dark\""), "\(text)")
        try await t.window.runUntil { (try? t.window.element(identifier: "theme-row-one-dark"))?.isSelected == true }
    }

    @Test func matchSystemShowsTwoFilteredLists() async throws {
        let t = try await setup()
        defer { t.controller.stop() }
        let picker = try t.window.element(identifier: "settings-theme-mode")
        let segment = try #require(descendants(of: picker, in: t.window).first { $0.label == "Match system" })
        try t.window.click(segment)
        try await t.window.runUntil { (try? t.window.element(identifier: "settings-theme-list-light")) != nil }
        #expect(t.controller.currentSettings.themeMode == .matchSystem)
        #expect(Set(rowIDs(t.window, prefix: "theme-row-light-")) == ["theme-row-light-alloy-light", "theme-row-light-solarized-light"])
        #expect(Set(rowIDs(t.window, prefix: "theme-row-dark-")) ==
                ["theme-row-dark-dracula", "theme-row-dark-alloy-dark", "theme-row-dark-solarized-dark", "theme-row-dark-one-dark"])
        #expect(try t.window.element(identifier: "theme-row-light-alloy-light").isSelected)
        #expect(try t.window.element(identifier: "theme-row-dark-dracula").isSelected)
        try t.window.click(t.window.element(identifier: "theme-row-light-solarized-light"))
        try t.window.click(t.window.element(identifier: "theme-row-dark-one-dark"))
        try await t.window.runUntil {
            t.controller.currentSettings.lightTheme == "solarized-light" && t.controller.currentSettings.darkTheme == "one-dark"
        }
        try await t.window.runUntil {
            (try? t.window.element(identifier: "theme-row-light-solarized-light"))?.isSelected == true
                && (try? t.window.element(identifier: "theme-row-dark-one-dark"))?.isSelected == true
        }
        #expect(try !t.window.element(identifier: "theme-row-light-alloy-light").isSelected)
        #expect(try !t.window.element(identifier: "theme-row-dark-dracula").isSelected)
    }

    @Test func userThemeAppearsAfterDrop() async throws {
        let t = try await setup(settings: AlloySettings(themeMode: .matchSystem))
        defer { t.controller.stop() }
        let dir = themesDirectory(t.rig)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("paper.json")
        try ##"{"name":"Paper","appearance":"light","colors":{"accent":"#112233"}}"##.write(to: url, atomically: true, encoding: .utf8)
        await t.controller.reload()
        try await t.window.runUntil { (try? t.window.element(identifier: "theme-row-light-user/paper")) != nil }
        #expect((try? t.window.element(identifier: "theme-row-dark-user/paper")) == nil)
        // And through the watcher.
        let second = dir.appendingPathComponent("night.json")
        try #"{"name":"Night","appearance":"dark"}"#.write(to: second, atomically: true, encoding: .utf8)
        t.watcher.send([second.path])
        try await t.window.runUntil { (try? t.window.element(identifier: "theme-row-dark-user/night")) != nil }
    }

    @Test func errorsAndNoticeShow() async throws {
        let t = try await setup(settings: AlloySettings(theme: "user/gone"))
        defer { t.controller.stop() }
        try await t.window.runUntil { (try? t.window.element(identifier: "settings-theme-notice")) != nil }
        let dir = themesDirectory(t.rig)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("broken.json")
        try "{\"name\":".write(to: url, atomically: true, encoding: .utf8)
        await t.controller.reload()
        try await t.window.runUntil { (try? t.window.element(identifier: "settings-theme-error-broken.json")) != nil }
        let notice = try t.window.element(identifier: "settings-theme-notice")
        #expect((notice.value ?? notice.label ?? "").contains("user/gone"))
    }

    @Test func twoErrorsOnOneFileBothShow() async throws {
        let t = try await setup()
        defer { t.controller.stop() }
        let dir = themesDirectory(t.rig)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("x.json")
        try ##"{"name":"X","appearance":"dark","base":"nope"}"##.write(to: url, atomically: true, encoding: .utf8)
        await t.controller.reload()
        // Now the file stops parsing: its last good version stays (still with the unknown base), so the file has two errors.
        try "{\"name\":".write(to: url, atomically: true, encoding: .utf8)
        await t.controller.reload()
        #expect(t.controller.library.errors.filter { $0.fileName == "x.json" }.count == 2)
        try await t.window.runUntil {
            (try? t.window.element(identifier: "settings-theme-error-x.json")) != nil
                && (try? t.window.element(identifier: "settings-theme-error-x.json-2")) != nil
        }
    }

    @Test func backToDraculaRestores() async throws {
        let t = try await setup(settings: AlloySettings(themeMode: .matchSystem, theme: "one-dark",
                                                        lightTheme: "solarized-light", darkTheme: "one-dark"))
        defer { t.controller.stop() }
        #expect(t.window.window.preferredColorScheme == nil)
        try t.window.click(t.window.element(identifier: "settings-back-to-dracula"))
        try await t.window.runUntil { t.controller.currentSettings.themeMode == .single }
        #expect(t.controller.currentSettings.theme == "dracula")
        #expect(t.window.window.preferredColorScheme == .dark)
        try await t.window.runUntil { (try? t.window.element(identifier: "theme-row-dracula"))?.isSelected == true }
    }

    @Test func makeThemeButtonStartsAThemeSession() async throws {
        let t = try await setup()
        defer { t.controller.stop() }
        try t.window.click(t.window.element(identifier: "settings-make-theme"))
        try await t.window.runUntil { (try? t.window.element(identifier: "settings-view")) == nil }
        await waitFor("the theme session exists") { t.rig.workspace.sessions.contains { $0.name == "Theme: new" } }
        await t.rig.workspace.settle()
        let session = try #require(t.rig.workspace.sessions.first { $0.id == t.rig.workspace.selectedSessionID })
        #expect(session.name == "Theme: new")
        #expect(session.purpose == .theme)
        await waitFor("the session launched") { t.rig.transports.count == 1 }
        await t.rig.workspace.stopAll()
    }

    @Test func openThemesFolderUsesOpener() async throws {
        let t = try await setup()
        defer { t.controller.stop() }
        let box = t.opened
        t.controller.folderOpener = { box.urls.append($0) }
        try t.window.click(t.window.element(identifier: "settings-open-themes"))
        #expect(box.urls == [themesDirectory(t.rig)])
        #expect(FileManager.default.fileExists(atPath: themesDirectory(t.rig).path))
    }

    @Test func rowsFitAtMinimumWidth() async throws {
        // The window's minimum is 900 pt; the split view then gives the chat column about 460 pt at the minimum sidebar.
        let t = try await setup(width: Pixels(900), settings: AlloySettings(themeMode: .matchSystem))
        defer { t.controller.stop() }
        let dir = themesDirectory(t.rig)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try #"{"name":"A Rather Long Custom Theme Name Indeed","author":"Somebody With A Long Name","appearance":"light"}"#
            .write(to: dir.appendingPathComponent("long.json"), atomically: true, encoding: .utf8)
        await t.controller.reload()
        try await t.window.runUntil { (try? t.window.element(identifier: "theme-row-light-user/long")) != nil }
        let window = t.window
        let section = try t.window.element(identifier: "settings-theme-section")
        for id in rowIDs(t.window, prefix: "theme-row-") {
            let row = try t.window.element(identifier: id)
            #expect(row.frame.minX >= section.frame.minX - 0.5 && row.frame.maxX <= section.frame.maxX + 0.5, "\(id) \(row.frame) in \(section.frame)")
            // Five 12 pt swatches and four 3 pt gaps, after the row's 6 pt padding: no label starts inside the strip.
            let stripEnd = Float(row.frame.minX.value) + Float(6 + 5 * 12 + 4 * 3)
            let glyphs = window.scene.glyphs.filter {
                !t.underneath.contains([$0.bounds.origin.x, $0.bounds.origin.y]) &&
                $0.bounds.origin.y >= Float(row.frame.minY.value) && $0.bounds.origin.y + $0.bounds.size.height <= Float(row.frame.maxY.value)
                    && $0.bounds.origin.x >= Float(row.frame.minX.value) - 1 && $0.bounds.origin.x < Float(row.frame.maxX.value)
            }
            #expect(!glyphs.isEmpty, "\(id) has text")
            for g in glyphs {
                #expect(g.bounds.origin.x >= stripEnd - 0.5, "\(id) label glyph at \(g.bounds.origin.x) overlaps the swatches (ends \(stripEnd))")
                #expect(g.bounds.origin.x + g.bounds.size.width <= Float(row.frame.maxX.value) + 0.5, "\(id) label runs past the row")
            }
        }
    }

    @Test func saveFailureShowsNextToTheControls() async throws {
        // A file where the support directory should be: the settings file cannot be created.
        let t = try await setup { try Data().write(to: $0.root.appendingPathComponent("support")) }
        defer { t.controller.stop() }
        try t.window.click(t.window.element(identifier: "theme-row-one-dark"))
        try await t.window.runUntil { (try? t.window.element(identifier: "settings-theme-save-error")) != nil }
        #expect((try? t.window.element(identifier: "settings-error")) == nil, "not the shared line")
        let section = try t.window.element(identifier: "settings-theme-section")
        let error = try t.window.element(identifier: "settings-theme-save-error")
        #expect(error.frame.minY >= section.frame.minY && error.frame.maxY <= section.frame.maxY)
    }

    @Test func rowRendersFiveSwatchesInTheThemesOwnColours() async throws {
        let t = try await setup()
        defer { t.controller.stop() }
        for id in ["dracula", "solarized-light", "one-dark"] {
            let resolved = try #require(t.controller.library.resolve(id))
            let frame = try t.window.element(identifier: "theme-row-\(id)").frame
            let expected: [ThemeRGBA] = try ["chatFill", "accent", "syntax.keyword", "syntax.string"].map {
                try #require(resolved.colors[$0], "\($0)")
            } + [try #require(resolved.sessionColors.first)]
            let squares = t.window.scene.rects.filter {
                $0.bounds.size.width == 12 && $0.bounds.size.height == 12
                    && $0.bounds.origin.x >= Float(frame.minX.value) && $0.bounds.origin.x < Float(frame.maxX.value)
                    && $0.bounds.origin.y >= Float(frame.minY.value) && $0.bounds.origin.y < Float(frame.maxY.value)
            }.sorted { $0.bounds.origin.x < $1.bounds.origin.x }
            // Each square is a fill plus a 1 pt border rect (so a swatch equal to the page colour stays visible).
            let swatches = squares.filter { $0.borderWidths.top == 0 }
            let borders = squares.filter { $0.borderWidths.top == 1 && $0.borderWidths.left == 1 && $0.borderColor.a > 0.99 }
            #expect(borders.count == 5, "\(id) borders")
            #expect(Set(borders.map { [$0.borderColor.h, $0.borderColor.s, $0.borderColor.l] }).count == 1, "\(id) one border colour")
            #expect(swatches.count == 5, "\(id)")
            for (rect, rgba) in zip(swatches, expected) {
                let want = rgba.hsla
                #expect(abs(rect.background.h - want.h) < 0.01 && abs(rect.background.s - want.s) < 0.01
                            && abs(rect.background.l - want.l) < 0.01, "\(id) swatch \(rect.background) vs \(want)")
            }
        }
    }
}
