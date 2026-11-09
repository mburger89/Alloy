import AlloyCore
@testable import AlloyKit
import AlloyTestSupport
import CoreGraphics
import Foundation
import ImageIO
import MetalUI
import MetalUIPlatform
import MetalUITesting
import Testing
import UniformTypeIdentifiers

@MainActor
@Suite(.serialized) struct AttachmentTests {
    private func png() -> Data {
        var pixels = [UInt8](repeating: 120, count: 4 * 4 * 4)
        let ctx = pixels.withUnsafeMutableBytes {
            CGContext(data: $0.baseAddress, width: 4, height: 4, bitsPerComponent: 8, bytesPerRow: 16,
                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        }
        let out = NSMutableData()
        let dest = CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
        CGImageDestinationFinalize(dest)
        return out as Data
    }

    private func settle(_ condition: @MainActor () -> Bool) async throws {
        for _ in 0..<20_000 {
            if condition() { return }
            await Task.yield()
        }
        Issue.record("timed out")
        throw CancellationError()
    }

    private func idleSession(_ rig: Rig) async throws -> Session {
        let session = await rig.workspace.newSession(name: "A")
        await rig.transports[0].emit(.result(TurnResult(subtype: "success", isError: false, costUSD: 0, inputTokens: 0,
                                                        outputTokens: 0, sessionID: "s", terminalReason: nil)))
        try await settle { session.status == .idle }
        return session
    }

    /// Ticks until no image is encoding in the window's composer (chips settle).
    private func settled(_ window: TestWindow) async throws {
        try await window.runUntil { (try? window.element(identifier: "attachment-pending")) == nil }
        window.tick()
    }

    private func chips(_ window: TestWindow, prefix: String = "attachment-chip-") throws -> [TestElement] {
        var seen = Set<String>()
        return try window.elements(where: { $0.identifier?.hasPrefix(prefix) == true }).filter { seen.insert($0.identifier ?? "").inserted }
    }

    private func fileItem(_ url: URL) -> DropItem {
        let type = PasteboardType(identifier: "public.file-url", conformsTo: ["public.url", "public.data", "public.item"])
        let bytes = [UInt8](url.absoluteString.utf8)
        return DropItem(types: [type]) { $0 == type.identifier ? bytes : nil }
    }

    private func composerWindow(_ rig: Rig) async throws -> TestWindow {
        _ = try await idleSession(rig)
        let window = try alloyWindow(rig.workspace)
        try window.focus(window.element(identifier: "composer"))
        return window
    }

    private func dropPoint(_ window: TestWindow) throws -> Point<Pixels> {
        let frame = try window.element(identifier: "composer").frame
        return Point(x: frame.origin.x + Pixels(10), y: frame.origin.y + Pixels(10))
    }

    @Test func pasteImageAddsChip() async throws {
        let rig = Rig()
        let window = try await composerWindow(rig)
        let item = ClipboardItem(payloads: [ClipboardPayload(type: PasteboardType(identifier: "public.png", conformsTo: ["public.image", "public.data", "public.item"]),
                                                             bytes: .now([UInt8](png())))])
        #expect(window.setClipboard(items: [item]))
        window.typeKey("v", modifierFlags: [.command])
        try await window.runUntil { ((try? self.chips(window).count) ?? 0) == 1 }
        #expect(try chips(window).count == 1)
        #expect(try chips(window, prefix: "attachment-remove-").count == 1)
        let composer = try window.element(identifier: "composer")
        #expect(composer.value ?? "" == "")
        try window.click(chips(window, prefix: "attachment-remove-")[0])
        window.tick()
        #expect(try chips(window).isEmpty)
    }

    @Test func pasteTextStaysText() async throws {
        let rig = Rig()
        let window = try await composerWindow(rig)
        window.setClipboard(text: "hello there")
        window.typeKey("v", modifierFlags: [.command])
        #expect(try chips(window).isEmpty)
        #expect(try window.element(identifier: "composer").value == "hello there")
    }

    @Test func dropImageFileAddsChip() async throws {
        let rig = Rig()
        let window = try await composerWindow(rig)
        let file = rig.root.appendingPathComponent("shot.png")
        try png().write(to: file)
        window.drop([fileItem(file)], at: try dropPoint(window))
        try await window.runUntil { ((try? self.chips(window).count) ?? 0) == 1 }
        #expect(try chips(window).count == 1)
        #expect(try window.element(identifier: "composer").value ?? "" == "")
    }

    @Test func dropSourceFileInsertsMention() async throws {
        let rig = Rig()
        let window = try await composerWindow(rig)
        try FileManager.default.createDirectory(at: rig.root.appendingPathComponent("src"), withIntermediateDirectories: true)
        let inside = rig.root.appendingPathComponent("src/main.swift")
        try "x".write(to: inside, atomically: true, encoding: .utf8)
        let outsideDir = FileManager.default.temporaryDirectory.appendingPathComponent("alloy-out-\(UUID().uuidString)").resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: outsideDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outsideDir) }
        let outside = outsideDir.appendingPathComponent("notes.txt")
        try "y".write(to: outside, atomically: true, encoding: .utf8)
        window.drop([fileItem(inside)], at: try dropPoint(window))
        #expect(try window.element(identifier: "composer").value == "@src/main.swift ")
        window.drop([fileItem(outside)], at: try dropPoint(window))
        #expect(try window.element(identifier: "composer").value == "@src/main.swift \(outside.path) ")
        #expect(try chips(window).isEmpty)
    }

    @Test func unreadableImageShowsErrorThatExpires() async throws {
        let rig = Rig()
        let session = try await idleSession(rig)
        let model = ComposerModel(workspace: rig.workspace, sessionID: session.id)
        model.errorDuration = .milliseconds(50)
        model.attach(imageData: Data("nope".utf8), typeHint: nil)
        try await settle { model.pending == 0 && model.error != nil }
        #expect(model.error == "Couldn't read that image")
        #expect(model.attachments.isEmpty)
        try await settle { model.error == nil }
    }

    @Test func errorShowsInView() async throws {
        let rig = Rig()
        let window = try await composerWindow(rig)
        let file = rig.root.appendingPathComponent("bad.png")
        try Data("nope".utf8).write(to: file)
        window.drop([fileItem(file)], at: try dropPoint(window))
        try await window.runUntil { (try? window.element(identifier: "composer-error")) != nil }
        #expect((try? window.element(identifier: "composer-error")) != nil)
    }

    @Test func sendCarriesImage() async throws {
        let rig = Rig()
        let session = try await idleSession(rig)
        let model = ComposerModel(workspace: rig.workspace, sessionID: session.id)
        model.attach(imageData: png(), typeHint: nil)
        model.draft = "look"
        model.send(priority: nil)   // immediately, while the image may still be encoding
        try await settle { model.pending == 0 && model.attachments.isEmpty }
        #expect(model.draft.isEmpty)
        var content: [UserContent] = []
        for _ in 0..<200_000 {
            let sent = await rig.transports[0].sent
            if case .user(let c, _, _)? = sent.last(where: { if case .user = $0 { true } else { false } }) { content = c; break }
            await Task.yield()
        }
        #expect(content.contains { if case .image(let type, _) = $0 { type == "image/png" } else { false } })
        #expect(content.contains(.text("look")))
    }

    @Test func mixedClipboardPastesTextNotImage() async throws {
        let rig = Rig()
        let window = try await composerWindow(rig)
        let png = ClipboardPayload(type: PasteboardType(identifier: "public.png", conformsTo: ["public.image", "public.data", "public.item"]),
                                   bytes: .now([UInt8](self.png())))
        let text = ClipboardPayload(type: PasteboardType(identifier: "public.utf8-plain-text", conformsTo: ["public.text", "public.data", "public.item"]),
                                    bytes: .now(Array("cells".utf8)))
        #expect(window.setClipboard(items: [ClipboardItem(payloads: [text, png])]))
        window.typeKey("v", modifierFlags: [.command])
        for _ in 0..<50 { window.tick(); await Task.yield() }
        #expect(try chips(window).isEmpty)
        #expect(try window.element(identifier: "composer").value == "cells")
    }

    @Test func mentionsQuotePathsWithSpaces() async throws {
        let rig = Rig()
        let session = try await idleSession(rig)
        let model = ComposerModel(workspace: rig.workspace, sessionID: session.id)
        try FileManager.default.createDirectory(at: rig.root.appendingPathComponent("my dir"), withIntermediateDirectories: true)
        let inside = rig.root.appendingPathComponent("my dir/a b.swift")
        try "x".write(to: inside, atomically: true, encoding: .utf8)
        model.handleDrop(fileURLs: [inside])
        #expect(model.draft == "@\"my dir/a b.swift\" ")
        #expect(ComposerModel.quoted("", "/tmp/x y") == "\"/tmp/x y\"")
    }

    @Test func composerRefusesOversizeImage() async throws {
        let rig = Rig()
        let session = try await idleSession(rig)
        let model = ComposerModel(workspace: rig.workspace, sessionID: session.id)
        model.imageLimit = 10
        model.attach(imageData: png(), typeHint: nil)
        try await settle { model.pending == 0 }
        #expect(model.attachments.isEmpty)
        #expect(model.error?.hasPrefix("Image is too large (") == true)
        #expect(model.error?.hasSuffix("MB, limit 5 MB)") == true)
    }

    @Test func deferredSendSnapshotsTextAtReturn() async throws {
        let rig = Rig()
        let session = try await idleSession(rig)
        let model = ComposerModel(workspace: rig.workspace, sessionID: session.id)
        model.attach(imageData: png(), typeHint: nil)   // the encode cannot finish before this test suspends
        model.draft = "hello"
        model.send(priority: nil)
        #expect(model.draft.isEmpty)
        model.draft = "extra"
        try await settle { model.pending == 0 }
        #expect(model.draft == "extra")
        var content: [UserContent] = []
        for _ in 0..<200_000 {
            let sent = await rig.transports[0].sent
            if case .user(let c, _, _)? = sent.last(where: { if case .user = $0 { true } else { false } }) { content = c; break }
            await Task.yield()
        }
        #expect(content.contains(.text("hello")))
        #expect(!content.contains(.text("extra")))
        #expect(content.contains { if case .image = $0 { true } else { false } })
    }

    /// Return pressed while an image encodes, then a switch to another session and back: the composer (and its
    /// deferred send) live above the chat column, so the message still goes out with the image.
    @Test func deferredSendAndDraftSurviveASessionSwitch() async throws {
        let rig = Rig()
        let a = try await idleSession(rig)
        let b = await rig.workspace.newSession(name: "B")
        rig.workspace.selectedSessionID = a.id
        let window = try alloyWindow(rig.workspace)
        let composer = try window.element(identifier: "composer")
        try window.focus(composer)
        let file = rig.root.appendingPathComponent("shot.png")
        try png().write(to: file)
        window.drop([fileItem(file)], at: try dropPoint(window))   // starts an encode off the main actor
        window.typeText("look")
        window.typeKey(.return)                                     // deferred until the encode finishes
        // Synchronous from here to the switch back, so the encode cannot finish while the column is gone.
        rig.workspace.selectedSessionID = b.id
        window.tick(); window.tick()
        try window.focus(window.element(identifier: "composer"))
        window.typeText("half typed")
        window.tick()
        rig.workspace.selectedSessionID = a.id
        window.tick(); window.tick()
        var content: [UserContent] = []
        for _ in 0..<200_000 {
            let sent = await rig.transports[0].sent
            if case .user(let c, _, _)? = sent.last(where: { if case .user = $0 { true } else { false } }) { content = c; break }
            window.tick()
            await Task.yield()
        }
        #expect(content.contains { if case .image(let type, _) = $0 { type == "image/png" } else { false } })
        #expect(content.contains { if case .text("look") = $0 { true } else { false } })
        // B's half-typed draft is still there after another round trip.
        rig.workspace.selectedSessionID = b.id
        window.tick(); window.tick()
        #expect(try window.element(identifier: "composer").value == "half typed")
    }
}
