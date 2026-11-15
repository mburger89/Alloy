import AlloyCore
import AlloyLSP
@testable import AlloyKit
import AlloyTestSupport
import Foundation
import MetalUI
import MetalUITesting
import Testing

/// The file panel's header in a narrow panel keeps each label on one line (truncating) instead of wrapping mid-word.
@MainActor
@Suite struct FilePanelHeaderWrapTests {
    @Test func narrowHeaderKeepsLabelsOnOneLine() throws {
        let rig = Rig()
        let path = "Sources/ForecastFeature/Views/ForecastDetailSummary.swift"
        let coordinator = LSPCoordinator.install(on: rig.workspace, builtIn: [],
                                                 locator: ServerLocator(loginPATH: { nil }, xcrunFind: { _ in nil }),
                                                 launcher: ServerLauncher { _, _, _ in throw CocoaError(.fileNoSuchFile) })
        coordinator.status.set(path: path, name: "sourcekit-lsp", state: .ready)
        let workspace = rig.workspace
        let window = try TestWindow(size: Size(width: Pixels(220), height: Pixels(120))) {
            VStack(alignment: .leading, spacing: 0) {
                FilePanelHeader(workspace: workspace, path: path, document: nil, view: nil)
            }
        }
        window.tick()
        window.tick()
        let pathFrame = try window.element(identifier: "file-panel-path").frame
        let statusFrame = try window.element(identifier: "file-panel-lsp-status").frame
        // One line of 12 pt / 11 pt text is well under two lines' height.
        #expect(pathFrame.size.height.value < 20, "path wrapped: \(pathFrame)")
        #expect(statusFrame.size.height.value < 18, "status wrapped: \(statusFrame)")
        // The status keeps its full width; the path is the label that gave up space.
        #expect(statusFrame.maxX.value <= 220 && pathFrame.maxX.value <= statusFrame.minX.value)
        #expect(statusFrame.size.width.value > 60)
    }
}
