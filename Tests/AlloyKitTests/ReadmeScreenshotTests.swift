import AlloyCore
@testable import AlloyKit
import Foundation
import MetalUI
import MetalUITesting
import MetalUITestingSnapshot
import Testing

/// Opt-in generator for the README images. Skipped unless `ALLOY_SCREENSHOTS=1`. It drives two real `claude` sessions
/// over a scratch copy of a small demo project (`ALLOY_DEMO_SRC`), then renders Alloy's UI headlessly in a
/// `TestWindow` and writes PNGs to `docs/images/`. No GUI window is ever opened. Costs a few cents on haiku.
private final class Recorder: @unchecked Sendable {
    private let lock = NSLock()
    private var _results = 0
    var results: Int { lock.withLock { _results } }
    func note(_ e: ProcessEvent) { if case .message(.result) = e { lock.withLock { _results += 1 } } }
}

private struct RecordingTransport: SessionTransport {
    let inner: ClaudeProcess
    let recorder: Recorder
    func start() async throws -> AsyncStream<ProcessEvent> {
        let upstream = try await inner.start()
        let recorder = recorder
        return AsyncStream { c in
            let task = Task { for await e in upstream { recorder.note(e); c.yield(e) }; c.finish() }
            c.onTermination = { _ in task.cancel() }
        }
    }
    func send(_ message: OutboundMessage) async throws { try await inner.send(message) }
    func terminate() async { await inner.terminate() }
    func stopAndWait(timeout: Duration) async { await inner.stopAndWait(timeout: timeout) }
}

private final class Recorders: @unchecked Sendable {
    private let lock = NSLock()
    private var list: [Recorder] = []
    func make() -> Recorder { let r = Recorder(); lock.withLock { list.append(r) }; return r }
    subscript(i: Int) -> Recorder { lock.withLock { list[i] } }
}

private enum ShotError: Error { case failed(String) }

@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["ALLOY_SCREENSHOTS"] == "1"))
struct ReadmeScreenshotTests {
    @MainActor private static func turn(_ ws: Workspace, _ s: Session, _ text: String, _ rec: Recorder) async throws {
        let before = rec.results
        await ws.send(text, to: s.id)
        let deadline = Date().addingTimeInterval(300)
        while Date() < deadline {
            if rec.results > before, s.status == .idle { await ws.settle(); return }
            if s.status == .awaitingPermission {
                for b in s.transcript.blocks {
                    if case .permission(let p) = b, p.state == .pending {
                        await ws.answerPermission(session: s.id, requestID: p.requestID, allow: true)
                    }
                }
            }
            if case .exited = s.status { throw ShotError.failed("session exited") }
            try? await Task.sleep(for: .milliseconds(250))
        }
        throw ShotError.failed("turn timed out: \(text)")
    }

    @MainActor private static func openWindow(_ ws: Workspace, width: Float = 1440) throws -> TestWindow {
        let w = try TestWindow(size: Size(width: Pixels(width), height: Pixels(900)), colorScheme: .dark, scaleFactor: 2) {
            rootView(workspace: ws)
        }
        for _ in 0..<4 { w.tick() }
        return w
    }

    @MainActor private static func settle(_ w: TestWindow, _ cond: () -> Bool = { true }) async throws {
        try await w.runUntil(timeout: .seconds(20)) { cond() }
        // Gutter decorations and highlighting land asynchronously; give them wall-clock time.
        for _ in 0..<15 { try await Task.sleep(for: .milliseconds(100)); w.advance(by: 0.1) }
    }

    /// Drags the sidebar divider to `sidebar` (if given), then the divider left of the file panel towards `x`
    /// (points; the chat's minimum width stops it). With `panelEdge`, an element id inside the panel, the panel's
    /// real left edge is measured and the drag repeated from there until it stops moving.
    @MainActor private static func layout(_ w: TestWindow, panelDividerTo x: Float, sidebarTo sidebar: Float? = nil,
                                          panelEdge: String? = nil, windowWidth: Float = 1440) async {
        func pause() async { for _ in 0..<5 { try? await Task.sleep(for: .milliseconds(100)); w.advance(by: 0.1) } }
        if let sidebar {
            w.drag(from: Point(x: Pixels(250), y: Pixels(450)), to: Point(x: Pixels(sidebar), y: Pixels(450)))
            await pause()
        }
        var from = windowWidth - 361
        for _ in 0..<3 {
            w.drag(from: Point(x: Pixels(from), y: Pixels(450)), to: Point(x: Pixels(x), y: Pixels(450)))
            await pause()
            guard let id = panelEdge, let el = try? w.element(identifier: id) else { return }
            let edge = Float(el.frame.origin.x.value)
            print("PANEL EDGE \(edge)")
            if abs(edge - from) < 4 { return }
            from = edge - 3
        }
    }

    /// Words that must never appear in a README image, read from this machine so no name is written here.
    private static var personal: [String] {
        [NSUserName(), NSHomeDirectory(), "/Users/", "claude-\(getuid())", "recalled-memory"].filter { !$0.isEmpty }
    }

    /// Fails on anything personal in the visible text (the accessibility tree of the rendered window).
    @MainActor private static func privacyCheck(_ w: TestWindow, _ ws: Workspace, _ what: String) throws {
        var lines: [String] = []
        for e in try w.elements(where: { _ in true }) {
            if let l = e.label { lines.append(l) }
            if let v = e.value { lines.append(v) }
        }
        for line in lines.joined(separator: "\n").split(separator: "\n") {
            for bad in Self.personal + ["@gmail", "private/tmp", "/tmp/"] where line.contains(bad) {
                for sess in ws.sessions { print("TRANSCRIPT \(sess.name): \(sess.transcript.blocks.map { "\($0)".prefix(300) })") }
                throw ShotError.failed("\(what): found \(bad) in: \(line.prefix(200))")
            }
        }
    }

    @MainActor private static func write(_ w: TestWindow, _ ws: Workspace, _ name: String, to dir: URL) throws {
        try privacyCheck(w, ws, name)
        let data = try w.snapshotPNG()
        let url = dir.appendingPathComponent(name)
        try data.write(to: url)
        // 2x renders are ~800 KB; 1280 px wide (the 2x render downscaled) keeps them readable and under the README's size budget.
        let sips = Process()
        sips.executableURL = URL(fileURLWithPath: "/usr/bin/sips")
        sips.arguments = ["-Z", "1280", url.path]
        sips.standardOutput = FileHandle.nullDevice
        try sips.run(); sips.waitUntilExit()
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
        print("SHOT: \(name) \(size) bytes")
    }

    @Test @MainActor func renderReadmeImages() async throws {
        // Dragging the divider autosaves the split widths into this process's defaults; other tests must not see them.
        let splitKey = "MetalUI.SplitView.alloy-main"
        UserDefaults.standard.removeObject(forKey: splitKey)
        defer { UserDefaults.standard.removeObject(forKey: splitKey) }
        let fm = FileManager.default
        let env = ProcessInfo.processInfo.environment
        let src = try #require(env["ALLOY_DEMO_SRC"], "set ALLOY_DEMO_SRC to the demo project")
        let repo = URL(fileURLWithPath: "/tmp/weather")
        try? fm.removeItem(at: repo)
        try fm.copyItem(atPath: src, toPath: repo.path)
        let supportRoot = fm.temporaryDirectory.appendingPathComponent("alloy-shots-support-\(UUID().uuidString.prefix(8))")
        defer { try? fm.removeItem(at: repo); try? fm.removeItem(at: supportRoot) }
        let images = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("docs/images")
        try fm.createDirectory(at: images, withIntermediateDirectories: true)

        let model = env["ALLOY_SHOT_MODEL"] ?? "haiku"
        let forecast = "Sources/Weather/Forecast.swift"
        var made: (Workspace, Session, Session)?
        // A red "Failed" tool block is real output but a poor README image, so a take with any failed call is
        // discarded and re-run (up to 4 takes), never edited.
        for take in 1...4 {
            // Every take is fully fresh: a new demo copy and a new app-support directory (the ledger and sessions
            // are stored per project there), so nothing from a discarded take leaks into the next.
            try? fm.removeItem(at: repo)
            try fm.copyItem(atPath: src, toPath: repo.path)
            let support = supportRoot.appendingPathComponent("take\(take)")
            try fm.createDirectory(at: support, withIntermediateDirectories: true)
            let recorders = Recorders()
            let ws = Workspace(projectRoot: repo, appSupport: support, settings: AlloySettings(),
                               makeTransport: { cfg in
                                   // The machine's own hooks, memory and global instructions must not leak into a README
                                   // image. `disableAllHooks` goes into the one settings JSON the launch builds (merged
                                   // into any that is already there), so there is a single `--settings` flag.
                                   var cfg = cfg
                                   var settings = (cfg.extraSettingsJSON.flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) } as? [String: Any]) ?? [:]
                                   settings["disableAllHooks"] = true
                                   cfg.extraSettingsJSON = (try? JSONSerialization.data(withJSONObject: settings, options: [.sortedKeys])).map { String(decoding: $0, as: UTF8.self) } ?? #"{"disableAllHooks":true}"#
                                   cfg.appendSystemPrompt = (cfg.appendSystemPrompt.map { $0 + "\n\n" } ?? "") + """
                                   Work directly in this small project yourself. Do not delegate to subagents, do not schedule wakeups or \
                                   background tasks, and do not consult memory tools. Use only paths relative to the project root in commands \
                                   and never print absolute paths or file owners (no `ls -l`). Keep replies short.
                                   """
                                   return RecordingTransport(inner: ClaudeProcess(configuration: cfg), recorder: recorders.make())
                               })
            let retry = await ws.newSession(name: "Retry")
            await ws.send("/model \(model)", to: retry.id)
            let averages = await ws.newSession(name: "Averages")
            await ws.send("/model \(model)", to: averages.id)
            do {
                try await Self.turn(ws, retry, "In ForecastService, add a retry with exponential backoff (3 attempts) to forecast(for:). Keep it small.", recorders[0])
                try await Self.turn(ws, averages, "Make averageHigh return nil for an empty list instead of 0, and update callers.", recorders[1])
                try await Self.turn(ws, retry, "Read Sources/Weather/Formatting.swift and reply with just: done.", recorders[0])
                try await Self.turn(ws, averages, "Briefly explain Formatting.swift.", recorders[1])
            } catch {
                await ws.stopAll(); throw error
            }
            var failures: [String] = []
            for s in [retry, averages] {
                for blk in s.transcript.blocks {
                    if case .tool(let t) = blk, t.status == ToolBlock.Status.failed { failures.append("\(s.name) \(t.name): \(t.resultText.prefix(300))") }
                    // Real output that names the machine's user is discarded with the take, never edited.
                    let text = "\(blk)"
                    for bad in Self.personal where text.contains(bad) {
                        failures.append("\(s.name) mentions \(bad)")
                    }
                }
            }
            for f in failures { print("FAILED TOOL (take \(take)): \(f)") }
            if failures.isEmpty || take == 4 { made = (ws, retry, averages); break }
            await ws.stopAll()
        }
        let (ws, retry, averages) = try #require(made)
        _ = retry
        defer { Task { await ws.stopAll() } }
        #expect(ws.ledger.files[forecast] != nil, "ledger has Forecast.swift")

        // Hero: Averages chat (edit diff), Forecast.swift inline with both sessions' gutter bars.
        ws.selectedSessionID = averages.id
        await ws.open(forecast)
        let hero = try Self.openWindow(ws)
        try await Self.settle(hero) { (try? hero.element(identifier: "code-view")) != nil }
        await Self.layout(hero, panelDividerTo: 700)
        // Scroll so the retry loop (Retry's gutter bars) and averageHigh (Averages') are both in view.
        let lines = (try? String(contentsOf: repo.appendingPathComponent(forecast), encoding: .utf8))?.components(separatedBy: "\n") ?? []
        if let at = lines.firstIndex(where: { $0.contains("func averageHigh") }) {
            await ws.open(forecast, revealLine: at + 1 + 6)
            try await Self.settle(hero)
        }
        // Scroll the chat up a little so the edit card's header is in view.
        hero.scroll(at: Point(x: Pixels(420), y: Pixels(300)), byDeltaX: 0, deltaY: 330)
        for _ in 0..<8 { try? await Task.sleep(for: .milliseconds(100)); hero.advance(by: 0.1) }
        try Self.write(hero, ws, "alloy-hero.png", to: images)
        hero.close()

        // Side by side.
        await ws.open(forecast, revealLine: 30, mode: .sideBySide)
        let sbs = try Self.openWindow(ws)
        try await Self.settle(sbs) { (try? sbs.element(identifier: "sbs-left")) != nil && ws.sideBySideBuilds >= 1 }
        // As much width as the code panel allows (its maximum is 800 pt): sidebar to its minimum, divider dragged left.
        await Self.layout(sbs, panelDividerTo: 300, sidebarTo: 200, panelEdge: "sbs-left")
        try Self.write(sbs, ws, "alloy-side-by-side.png", to: images)
        sbs.close()

        // Shared knowledge: Averages' chat, chip expanded.
        // The chat is the focus here: no file open, and the panel pushed to its minimum width.
        ws.selectedSessionID = averages.id
        await ws.close(forecast)
        UserDefaults.standard.removeObject(forKey: splitKey)   // the side-by-side shot's widths
        let shared = try Self.openWindow(ws)
        await Self.layout(shared, panelDividerTo: 1300)
        var chipID: UUID?
        for b in averages.transcript.blocks { if case .user(let id, let t, _, _) = b, t.contains("Briefly explain"), ws.sharedFiles[id] != nil { chipID = id } }
        let id = try #require(chipID, "Averages' message carries a shared chip")
        let chip = "user-shared-\(id.uuidString)"
        try await Self.settle(shared) { (try? shared.element(identifier: chip)) != nil }
        try shared.click(shared.element(identifier: chip))
        try await Self.settle(shared) { (try? shared.element(identifier: "user-shared-detail-\(id.uuidString)")) != nil }
        try Self.write(shared, ws, "alloy-shared-knowledge.png", to: images)
        shared.close()
        await ws.stopAll()
    }
}
