import AlloyCore
@testable import AlloyKit
import AlloyTestSupport
import CoreGraphics
import Foundation
import ImageIO
import MetalUI
import MetalUITesting
import MetalUITestingSnapshot
import Testing
import UniformTypeIdentifiers

@MainActor
@Suite struct BackgroundImageTests {
    private final class Holder { var controller: ThemeController? }

    @MainActor private final class Host: ThemeHost {
        var lightTheme: Theme = .light
        var darkTheme: Theme = .dark
        var preferredColorScheme: ColorScheme?
    }

    /// A solid-colour PNG (generated here, nothing personal) of `width` x `height`.
    private func writePNG(_ url: URL, red: UInt8, green: UInt8, blue: UInt8, width: Int = 64, height: Int = 48) throws {
        var data = [UInt8](repeating: 255, count: width * height * 4)
        for i in 0..<(width * height) { data[i * 4] = red; data[i * 4 + 1] = green; data[i * 4 + 2] = blue }
        let ctx = try #require(CGContext(data: &data, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                         space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                         bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let image = try #require(ctx.makeImage())
        let dest = try #require(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(dest, image, nil)
        #expect(CGImageDestinationFinalize(dest))
    }

    private func pixel(_ image: CGImage, _ x: Int, _ y: Int) -> [Int] {
        var data = [UInt8](repeating: 0, count: 4)
        let ctx = CGContext(data: &data, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(image, in: CGRect(x: -x, y: -(image.height - 1 - y), width: image.width, height: image.height))
        return data.map(Int.init)
    }

    private func tempDirectory() throws -> URL {
        let dir = TempFiles.url("alloy-bgimage")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func controller(_ rig: Rig) -> ThemeController {
        let c = ThemeController(workspace: rig.workspace, host: Host(), watcher: nil)
        c.stop()
        return c
    }

    private func themesDirectory(_ rig: Rig) -> URL {
        ThemeLibrary.userDirectory(appSupport: rig.appSupport)
    }

    private func writeTheme(_ rig: Rig, _ stem: String, style: String) throws {
        let dir = themesDirectory(rig)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try #"{"name":"\#(stem)","appearance":"dark","base":"dracula","style":\#(style)}"#
            .write(to: dir.appendingPathComponent(stem + ".json"), atomically: true, encoding: .utf8)
    }

    // MARK: Theme key

    @Test func themeKeysDecodeAndResolveNextToTheThemeFile() throws {
        let file = try ThemeFile.parse(Data(#"{"name":"t","appearance":"dark","style":{"backgroundImage":"sky.png","backgroundImageDim":0.5}}"#.utf8))
        #expect(file.style?.backgroundImage == "sky.png" && file.style?.backgroundImageDim == 0.5)
        let folder = URL(fileURLWithPath: "/themes", isDirectory: true)
        var library = ThemeLibrary(builtIns: BuiltInThemes.all, userDirectory: folder)
        library.user = [ThemeEntry(id: "user/t", file: file, isBuiltIn: false, url: folder.appendingPathComponent("t.json"))]
        let resolved = try #require(library.resolve("user/t"))
        #expect(resolved.backgroundImageName == "sky.png")
        #expect(resolved.backgroundImageURL?.path == "/themes/sky.png")
        #expect(resolved.style.backgroundImageDim == 0.5)
        // A theme based on it inherits the key and resolves it against the file that names it.
        let child = try ThemeFile.parse(Data(#"{"name":"c","appearance":"dark","base":"t"}"#.utf8))
        library.user.append(ThemeEntry(id: "user/c", file: child, isBuiltIn: false, url: folder.appendingPathComponent("c.json")))
        #expect(library.resolve("user/c")?.backgroundImageURL?.path == "/themes/sky.png")
        // Built-ins have none; absolute and home-relative names are not followed; a wrong type is ignored.
        let dracula = try #require(library.resolve("dracula"))
        #expect(dracula.backgroundImageName == nil && dracula.style.backgroundImageDim == 0.30)
        let abs = try ThemeFile.parse(Data(#"{"name":"a","appearance":"dark","style":{"backgroundImage":"/etc/hosts"}}"#.utf8))
        library.user.append(ThemeEntry(id: "user/a", file: abs, isBuiltIn: false, url: folder.appendingPathComponent("a.json")))
        #expect(library.resolve("user/a")?.backgroundImageURL == nil)
        let wrong = try ThemeFile.parse(Data(#"{"name":"w","appearance":"dark","style":{"backgroundImage":3,"backgroundImageDim":9}}"#.utf8))
        #expect(wrong.style?.backgroundImage == nil)
        library.user.append(ThemeEntry(id: "user/w", file: wrong, isBuiltIn: false, url: folder.appendingPathComponent("w.json")))
        #expect(library.resolve("user/w")?.style.backgroundImageDim == 0.80, "clamped")
        // A draft resolves against the user themes folder.
        let draft = library.resolve(draft: file).theme
        #expect(draft.backgroundImageURL?.path == "/themes/sky.png")
    }

    @Test func missingThemeImageFallsBackWithoutAnImage() throws {
        let rig = Rig()
        try writeTheme(rig, "gone", style: #"{"backgroundImage":"nope.png"}"#)
        try rig.workspace.updateSettings(AlloySettings(theme: "user/gone"))
        let c = controller(rig)
        let image = try #require(c.style.backgroundImage)
        #expect(!image.exists && image.name == "nope.png", "Settings can say 'Image not found: nope.png'")
        // A directory, or a file that is not an image, is not decoded; a missing one is nil.
        #expect(ImageBitmap(contentsOfFile: image.path) == nil)
    }

    // MARK: Settings and the store

    @Test func settingsMapPersistsAndOldFilesStillLoad() throws {
        var s = AlloySettings()
        s.backgroundImages = ["dracula": "dracula.png", "user/x": ""]
        let back = try JSONDecoder().decode(AlloySettings.self, from: JSONEncoder().encode(s))
        #expect(back.backgroundImages == s.backgroundImages)
        let old = try JSONDecoder().decode(AlloySettings.self, from: Data(#"{"theme":"dracula","glass":false}"#.utf8))
        #expect(old.backgroundImages.isEmpty && !old.glass)
        let bad = try JSONDecoder().decode(AlloySettings.self, from: Data(#"{"backgroundImages":[1,2]}"#.utf8))
        #expect(bad.backgroundImages.isEmpty)
    }

    @Test func storeCopiesIntoItsFolderAndReplacesThemesEarlierCopy() throws {
        let dir = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = BackgroundImageStore(appSupport: dir.appendingPathComponent("support"))
        let a = dir.appendingPathComponent("a.PNG"), b = dir.appendingPathComponent("b.jpg")
        try writePNG(a, red: 255, green: 0, blue: 0)
        try writePNG(b, red: 0, green: 0, blue: 255)
        let first = try store.adopt(a, themeID: "user/my theme", replacing: nil)
        #expect(first == "user-my-theme.png")
        #expect(FileManager.default.fileExists(atPath: store.directory.appendingPathComponent(first).path))
        let second = try store.adopt(b, themeID: "user/my theme", replacing: first)
        #expect(second == "user-my-theme.jpg")
        #expect(!FileManager.default.fileExists(atPath: store.directory.appendingPathComponent(first).path), "the earlier copy is gone")
        #expect(FileManager.default.fileExists(atPath: a.path), "the source is left alone")
        store.delete(second)
        #expect(!FileManager.default.fileExists(atPath: store.directory.appendingPathComponent(second).path))
        let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: store.directory.path)) ?? []
        #expect(leftovers.isEmpty, "no temp files: \(leftovers)")
    }

    // MARK: Per-theme choice

    @Test func eachThemeKeepsItsOwnImageAndSwitchingSwitchesIt() throws {
        let rig = Rig()
        let src = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: src) }
        let red = src.appendingPathComponent("red.png"), blue = src.appendingPathComponent("blue.png")
        try writePNG(red, red: 255, green: 0, blue: 0)
        try writePNG(blue, red: 0, green: 0, blue: 255)
        let c = controller(rig)
        #expect(c.style.backgroundImage == nil)
        try c.setBackgroundImage(from: red)
        let dracula = try #require(c.style.backgroundImage)
        #expect(dracula.exists && dracula.name == "dracula.png")
        #expect(dracula.path.hasPrefix(rig.appSupport.path), "the copy lives in the temp app support")
        try c.choose(theme: "alloy-dark")
        #expect(c.style.backgroundImage == nil, "another theme has its own (here no) image")
        try c.setBackgroundImage(from: blue)
        #expect(c.style.backgroundImage?.name == "alloy-dark.png")
        try c.choose(theme: "dracula")
        #expect(c.style.backgroundImage?.name == "dracula.png")
        let saved = AlloySettings.load(appSupport: rig.appSupport)
        #expect(saved.backgroundImages == ["dracula": "dracula.png", "alloy-dark": "alloy-dark.png"])
        // Match system: each of light and dark has its own, and the one showing now is the one that changes.
        try c.choose(mode: .matchSystem, light: "alloy-light", dark: "dracula")
        c.systemScheme = { .light }
        c.refreshStyle()
        #expect(c.style.backgroundImage == nil)
        c.systemScheme = { .dark }
        c.refreshStyle()
        #expect(c.style.backgroundImage?.name == "dracula.png")
    }

    @Test func removeDeletesTheCopyAndHidesAThemeFilesOwnImage() throws {
        let rig = Rig()
        let src = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: src) }
        let red = src.appendingPathComponent("red.png")
        try writePNG(red, red: 255, green: 0, blue: 0)
        let c = controller(rig)
        try c.setBackgroundImage(from: red)
        let copy = try #require(c.style.backgroundImage).path
        try c.removeBackgroundImage()
        #expect(c.style.backgroundImage == nil)
        #expect(!FileManager.default.fileExists(atPath: copy))
        #expect(c.currentSettings.backgroundImages.isEmpty)

        // A theme file that names an image: it shows, the user's pick wins, and Remove hides it without editing the file.
        try writeTheme(rig, "own", style: #"{"backgroundImage":"own.png"}"#)
        try writePNG(themesDirectory(rig).appendingPathComponent("own.png"), red: 0, green: 255, blue: 0)
        let themeFile = themesDirectory(rig).appendingPathComponent("own.json")
        let before = try Data(contentsOf: themeFile)
        let c2 = controller(rig)
        try c2.choose(theme: "user/own")
        #expect(c2.style.backgroundImage?.name == "own.png" && c2.style.backgroundImage?.exists == true)
        try c2.setBackgroundImage(from: red)
        #expect(c2.style.backgroundImage?.name == "user-own.png", "the settings map wins over the theme's key")
        try c2.removeBackgroundImage()
        #expect(c2.style.backgroundImage == nil, "hidden")
        #expect(c2.currentSettings.backgroundImages["user/own"] == BackgroundImageStore.hidden)
        #expect(try Data(contentsOf: themeFile) == before, "the theme file is never rewritten")
        #expect(AlloySettings.load(appSupport: rig.appSupport).backgroundImages["user/own"] == "")
        // Another theme is untouched, and Back to Dracula leaves the images alone.
        try c2.backToDracula()
        #expect(c2.currentSettings.backgroundImages["user/own"] == "")
    }

    @Test func resetToThemeClearsTheDimButNotTheImage() throws {
        let rig = Rig()
        let src = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: src) }
        let red = src.appendingPathComponent("red.png")
        try writePNG(red, red: 255, green: 0, blue: 0)
        let c = controller(rig)
        try c.setBackgroundImage(from: red)
        var s = c.currentSettings
        s.appearance.backgroundImageDim = 0.6
        try rig.workspace.updateSettings(s)
        #expect(c.style.backgroundImageDim == 0.6)
        try c.choose(clearingAppearance: true)
        #expect(c.style.backgroundImageDim == AppearanceStyle.defaultImageDim)
        #expect(c.style.backgroundImage != nil, "images are a separate choice")
    }

    // MARK: Drawing

    /// Renders the backdrop over Dracula, waiting for the image to decode, and returns the top-left pixel.
    private func render(_ style: AppearanceStyle, waiting: Bool) async throws -> [Int] {
        let resolved = try #require(ThemeLibrary(builtIns: BuiltInThemes.all).resolve("dracula"))
        let window = try TestWindow(size: Size(width: Pixels(400), height: Pixels(300)), colorScheme: .dark) {
            VStack(spacing: 0) { }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background { WindowBackdropView(style: style).equatable() }
        }
        window.window.darkTheme = ThemeApplier.theme(for: resolved)
        for _ in 0..<(waiting ? 60 : 4) {
            window.window.setNeedsRedraw()
            window.tick()
            if waiting { try await Task.sleep(for: .milliseconds(20)) }
        }
        return pixel(try window.snapshot(), 200, 150)
    }

    @Test func theImageIsDrawnAndTheDimLiesOverIt() async throws {
        let dir = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("red.png")
        try writePNG(file, red: 255, green: 0, blue: 0)
        var style = AppearanceStyle.defaults
        let without = try await render(style, waiting: false)
        style.backgroundImage = BackgroundImage(name: "red.png", path: file.path, exists: true)
        style.backgroundImageDim = 0
        let bare = try await render(style, waiting: true)
        #expect(bare != without)
        #expect(bare[0] > 200 && bare[1] < 60 && bare[2] < 60, "an undimmed red image: \(bare)")
        style.backgroundImageDim = 0.8
        let dimmed = try await render(style, waiting: true)
        #expect(dimmed[0] < bare[0] - 50, "the dim pulls it towards the window colour: \(dimmed) vs \(bare)")
        // A missing file draws as if there were no image.
        style.backgroundImage = BackgroundImage(name: "x.png", path: dir.appendingPathComponent("x.png").path, exists: false)
        let missing = try await render(style, waiting: false)
        #expect(missing == without)
    }

    // MARK: Settings window

    @Test func settingsShowsTheImageControlsAndTheDimSlider() async throws {
        let rig = Rig()
        let src = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: src) }
        let red = src.appendingPathComponent("red.png")
        try writePNG(red, red: 255, green: 0, blue: 0)
        let holder = Holder()
        let window = try TestWindow(size: Size(width: Pixels(1200), height: Pixels(900))) {
            rootView(workspace: rig.workspace, themes: holder.controller, center: testCenter(for: rig.workspace))
        }
        let c = ThemeController(workspace: rig.workspace, host: window.testApp.app, watcher: ScriptedChangeSource())
        holder.controller = c
        defer { c.stop() }
        window.installAlloyMenu(rig.workspace, themes: c)
        window.tick(); window.tick()
        let settings = try window.openSettingsFromMenu()
        try await settings.runUntil { (try? settings.element(identifier: "settings-appearance-reset")) != nil }
        _ = try settings.element(identifier: "settings-appearance-background-image")
        #expect((try? settings.element(identifier: "settings-appearance-background-image-remove")) == nil)
        #expect((try? settings.element(identifier: "settings-appearance-image-dim")) == nil)

        try c.setBackgroundImage(from: red)
        for _ in 0..<4 { window.tick(); settings.tick(); await Task.yield() }
        _ = try settings.element(identifier: "settings-appearance-background-image-remove")
        let slider = try settings.element(identifier: "settings-appearance-image-dim")
        try settings.performAccessibilityAction(.increment, on: slider)
        try settings.performAccessibilityAction(.increment, on: slider)
        let dim = try #require(rig.workspace.settings.appearance.backgroundImageDim)
        #expect(abs(dim - 0.32) < 1e-9, "live")
        #expect(abs(c.style.backgroundImageDim - 0.32) < 1e-9)
        try settings.click(settings.element(identifier: "settings-appearance-reset"))
        for _ in 0..<4 { window.tick(); settings.tick(); await Task.yield() }
        #expect(rig.workspace.settings.appearance.backgroundImageDim == nil)
        #expect(c.style.backgroundImage != nil, "Reset to theme keeps the image")
        try settings.click(settings.element(identifier: "settings-appearance-background-image-remove"))
        for _ in 0..<4 { window.tick(); settings.tick(); await Task.yield() }
        #expect(c.style.backgroundImage == nil)
        #expect((try? settings.element(identifier: "settings-appearance-background-image-remove")) == nil)
    }

    @Test func decodeCapsTheLongEdge() throws {
        let url = TempFiles.url("alloy-bg-big", ext: ".png")
        defer { try? FileManager.default.removeItem(at: url) }
        try writePNG(url, red: 10, green: 20, blue: 30, width: 4000, height: 3000)
        let bitmap = try #require(BackgroundImageLayer.decode(path: url.path))
        #expect(max(bitmap.width, bitmap.height) <= alloyBackgroundImageMaxPixelSize)
        #expect(bitmap.width == 2560 && bitmap.height == 1920)
    }

    @Test func decodeKeepsASmallImageAtItsSize() throws {
        let url = TempFiles.url("alloy-bg-small", ext: ".png")
        defer { try? FileManager.default.removeItem(at: url) }
        try writePNG(url, red: 10, green: 20, blue: 30, width: 1000, height: 800)
        let bitmap = try #require(BackgroundImageLayer.decode(path: url.path))
        #expect(bitmap.width == 1000 && bitmap.height == 800)
    }
}
