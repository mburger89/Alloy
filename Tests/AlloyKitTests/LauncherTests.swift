import AlloyCore
import AlloyKit
import AlloyTestSupport
import Foundation
import MetalUI
import MetalUITesting
import Testing

@MainActor
@Suite struct LauncherTests {
    @Test func chooserShowsUntilAProjectIsAdopted() throws {
        let rig = Rig()
        let model = LauncherModel()
        var asked = 0
        model.chooseFolder = { asked += 1 }
        let window = try TestWindow(size: Size(width: Pixels(1200), height: Pixels(800))) { launcherRoot(model: model) }
        window.tick()
        try window.click(window.element(identifier: "choose-folder"))
        window.tick()
        #expect(asked == 1)
        model.adopt(rig.workspace)
        window.tick(); window.tick()
        #expect((try? window.element(identifier: "new-session")) != nil)
        #expect((try? window.element(identifier: "choose-folder")) == nil)
    }

    @Test func closeRequestStopsEverySessionBeforeTheWindowCloses() async throws {
        let rig = Rig()
        let model = LauncherModel(workspace: rig.workspace)
        _ = await rig.workspace.newSession(name: "A")
        _ = await rig.workspace.newSession(name: "B")
        let window = try TestWindow(size: Size(width: Pixels(1200), height: Pixels(800))) { launcherRoot(model: model) }
        installWindowShutdown(on: window.window, model: model)
        window.tick()
        #expect(window.requestClose() == false, "the close is deferred")
        try await window.runUntil { window.platformWindow.isClosed }
        #expect(await rig.transports[0].stopAndWaitCalls == 1)
        #expect(await rig.transports[1].stopAndWaitCalls == 1)
    }

    @Test func terminateRequestRepliesTrueOnlyAfterEverySessionStopped() async throws {
        let rig = Rig()
        let model = LauncherModel(workspace: rig.workspace)
        _ = await rig.workspace.newSession(name: "A")
        var replies: [Bool] = []
        let answer = model.shutdownRequested { replies.append($0) }
        #expect(answer == .later)
        while replies.isEmpty { await Task.yield() }
        #expect(replies == [true])
        #expect(await rig.transports[0].stopAndWaitCalls == 1)
    }


    @Test func overlappingCloseAndTerminateBothGetOneReply() async throws {
        let rig = Rig()
        let model = LauncherModel(workspace: rig.workspace)
        _ = await rig.workspace.newSession(name: "A")
        var closeReplies: [Bool] = []
        var quitReplies: [Bool] = []
        #expect(model.shutdownRequested { closeReplies.append($0) } == .later)
        #expect(model.shutdownRequested { quitReplies.append($0) } == .later)
        while closeReplies.isEmpty || quitReplies.isEmpty { await Task.yield() }
        for _ in 0..<200 { await Task.yield() }
        #expect(closeReplies == [true])
        #expect(quitReplies == [true])
        #expect(await rig.transports[0].stopAndWaitCalls == 1)
    }

    @Test func closeWithoutAProjectClosesAtOnce() {
        let model = LauncherModel()
        #expect(model.shutdownRequested { _ in } == .now)
    }
}

/// Records what the watched file held at the moment each process was stopped.
private actor RecordingTransport: SessionTransport {
    private let stream: AsyncStream<ProcessEvent>
    private(set) var diskAtStop: [String] = []
    private let file: URL
    init(file: URL) { self.file = file; (stream, _) = AsyncStream.makeStream() }
    func start() async throws -> AsyncStream<ProcessEvent> { stream }
    func send(_ message: OutboundMessage) async throws {}
    func terminate() async {}
    func stopAndWait(timeout: Duration) async {
        diskAtStop.append((try? String(contentsOf: file, encoding: .utf8)) ?? "<missing>")
    }
}

extension LauncherTests {
    @Test func quitSavesBeforeStop() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("alloy-q-\(UUID().uuidString)").resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("a.txt")
        try "hello".write(to: file, atomically: true, encoding: .utf8)
        let transport = RecordingTransport(file: file)
        let workspace = Workspace(projectRoot: root, appSupport: root.appendingPathComponent("support"), settings: AlloySettings(),
                                  locate: { _ in URL(fileURLWithPath: "/fake/claude") }, makeTransport: { _ in transport },
                                  autosaveClock: ManualClock())
        let model = LauncherModel(workspace: workspace)
        _ = await workspace.newSession(name: "A")
        await workspace.open("a.txt")
        let doc = try #require(workspace.document("a.txt"))
        _ = doc.buffer.replace(0..<0, with: "typed ")
        var replies: [Bool] = []
        #expect(model.shutdownRequested { replies.append($0) } == .later)
        while replies.isEmpty { await Task.yield() }
        #expect(await transport.diskAtStop == ["typed hello"])
        #expect(!doc.isDirty)
    }
}
