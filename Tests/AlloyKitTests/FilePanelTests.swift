import AlloyCore
import AlloyKit
import AlloyTestSupport
import Foundation
import MetalUI
import MetalUITesting
import Testing

/// The panel container and the identifiers Bench and the earlier tests rely on.
@MainActor
@Suite struct FilePanelTests {
    private func ids(_ window: TestWindow) throws -> [String] {
        try window.elements(where: { _ in true }).compactMap(\.identifier)
    }

    @Test func clickingChangedFileOpensPanel() async throws {
        let (rig, _) = try await editedRig()
        let window = try alloyWindow(rig.workspace)
        try await window.runUntil { (try? window.element(identifier: "changed-file-login.swift")) != nil }
        #expect(rig.workspace.openFilePath == nil)
        try window.click(window.element(identifier: "changed-file-login.swift"))
        try await window.runUntil { rig.workspace.openFilePath == "login.swift" }
        try await window.runUntil { (try? window.element(identifier: "code-view")) != nil }
        #expect(try ids(window).contains("file-panel-path"))
    }

    @Test func emptyPanelShowsMessage() throws {
        let rig = Rig()
        let window = try alloyWindow(rig.workspace)
        let all = try ids(window)
        #expect(all.contains("file-panel") && all.contains("file-panel-message"))
        #expect(!all.contains("file-panel-path"))
    }

    @Test func fileOutsideTheProjectIsNotRead() async throws {
        let rig = Rig()
        rig.workspace.openFilePath = "../escape.txt"
        let window = try alloyWindow(rig.workspace)
        try await window.runUntil { (try? window.element(identifier: "file-panel-message")) != nil }
        #expect(try ids(window).contains("file-panel-path"))
    }

    @Test func missingFileShowsMessage() async throws {
        let rig = Rig()
        rig.workspace.openFilePath = "nope.txt"
        let window = try alloyWindow(rig.workspace)
        try await window.runUntil { (try? window.element(identifier: "file-panel-message")) != nil }
    }

    @Test func binaryFileShowsMessage() async throws {
        let rig = Rig()
        try Data([0x41, 0x00, 0x42]).write(to: rig.root.appendingPathComponent("b.bin"))
        rig.workspace.openFilePath = "b.bin"
        let window = try alloyWindow(rig.workspace)
        // "Loading…" uses the same identifier, so wait for the final message rather than any message.
        try await window.runUntil {
            let e = try? window.element(identifier: "file-panel-message")
            return e?.label?.contains("Loading") == false || e?.value?.contains("Loading") == false
        }
        #expect(try window.element(identifier: "file-panel-message").label?.contains("Binary") == true
                || window.element(identifier: "file-panel-message").value?.contains("Binary") == true)
    }

    @Test func fileArgumentIsVisibleRightAfterLaunch() async throws {
        let rig = Rig()
        try "alpha\nbeta\n".write(to: rig.root.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        rig.workspace.openFilePath = "a.txt"
        let window = try alloyWindow(rig.workspace)
        try await window.runUntil { (try? window.element(identifier: "code-view")) != nil }
        #expect(try ids(window).contains("file-panel-path"))
    }
}
