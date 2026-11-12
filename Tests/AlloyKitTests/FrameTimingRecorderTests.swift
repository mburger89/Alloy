import AlloyCore
import Foundation
import MetalUI
import MetalUITesting
import Testing
@testable import AlloyKit

private struct KeyBox: Component {
    @State var presses = 0
    var content: some ElementGroup {
        Box().frame(width: Pixels(20 + Float(presses)), height: Pixels(20)).background(.accent)
            .focusable()
            .onKeyPress("a") { presses += 1; return .handled }
    }
}

@MainActor
@Suite struct FrameTimingRecorderTests {
    private func makeWindow() throws -> TestWindow {
        try TestWindow(size: Size(width: Pixels(400), height: Pixels(300))) { VStack(spacing: 0) { KeyBox() } }
    }

    @Test func offWithoutFlag() throws {
        let window = try makeWindow()
        window.window.frameTiming = nil
        #expect(FrameTimingRecorder.install(on: window.window, environment: [:]) == nil)
        #expect(window.window.frameTiming == nil)
        #expect(FrameTimingRecorder.install(on: window.window, environment: ["ALLOY_FRAME_TIMING": "1"]) == nil)
        #expect(window.window.frameTiming == nil)
    }

    @Test func onWithFlagAndDataDir() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("alloy-ft-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let window = try makeWindow()
        let url = FrameTimingRecorder.install(on: window.window,
                                              environment: ["ALLOY_FRAME_TIMING": "1", "ALLOY_DATA_DIR": dir.path])
        #expect(url?.lastPathComponent == FrameTimingDump.fileName)
        #expect(url?.deletingLastPathComponent().path == dir.path)
        let timing = try #require(window.window.frameTiming)
        window.typeKey(.tab)
        window.typeKey("a")
        try FrameTimingRecorder.write(timing, to: try #require(url))
        let frames = try FrameTimingDump.decode(Data(contentsOf: try #require(url)))
        #expect(frames.count >= 2)
        #expect(frames.allSatisfy { $0.buildNs < 60_000_000_000 && $0.encodeNs < 60_000_000_000 })
    }
}
