import AlloyCore
@testable import AlloyKit
import AlloyTestSupport
import Foundation
import MetalUI
import MetalUITesting
import Testing

/// The edit card's Keep / Revert / Open buttons in a narrow chat column keep each label on one line.
@MainActor
@Suite struct EditActionsNarrowTests {
    private func editID(_ rig: Rig, _ session: Session) -> UUID? {
        for case .tool(let t) in session.transcript.blocks where t.toolUseID == "tool1" { return t.editIDs.first }
        return nil
    }

    @Test func narrowColumnKeepsButtonLabelsOnOneLine() async throws {
        let rig = Rig()
        let session = await rig.workspace.newSession(name: "A")
        let url = rig.root.appendingPathComponent("Sources/ForecastFeature/ForecastDetailSummary.swift")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "let role = \"root\"\n".write(to: url, atomically: true, encoding: .utf8)
        await rig.transports[0].emit(.assistantBlock(messageID: "m1", block: .toolUse(
            id: "tool1", name: "Edit", input: .object(["file_path": .string(url.path)]))))
        await rig.transports[0].emit(.toolResult(ToolResultMessage(
            toolUseID: "tool1", isError: false, text: "ok",
            result: .edit(filePath: url.path, originalFile: "let role = \"admin\"\n", hunks: [
                PatchHunk(oldStart: 1, oldLines: 1, newStart: 1, newLines: 1,
                          lines: ["-let role = \"admin\"", "+let role = \"root\""])]))))
        for _ in 0..<20_000 where editID(rig, session) == nil { await Task.yield() }
        let id = try #require(editID(rig, session))
        let record = try #require(rig.workspace.editRecord(id: id))
        let workspace = rig.workspace
        let width: Float = 220
        let window = try TestWindow(size: Size(width: Pixels(width), height: Pixels(300))) {
            VStack(alignment: .leading, spacing: 0) {
                EditActions(workspace: workspace, record: record, conflict: nil)
            }
        }
        window.tick()
        window.tick()
        for name in ["keep", "revert", "open-in-file", "side-by-side"] {
            let frame = try window.element(identifier: "\(name)-\(id.uuidString)").frame
            // One line of button text is about 24 pt tall; a label broken per character is several times that.
            #expect(frame.size.height.value < 30, "\(name) wrapped: \(frame)")
            #expect(frame.size.width.value > 40, "\(name) squeezed: \(frame)")
            #expect(frame.maxX.value <= width, "\(name) overflows: \(frame)")
        }
    }
}
