import AppKit
import CoreGraphics
import Darwin
import Foundation
import BenchCore
import BenchDrivers

/// Thread-safe value holder shared between a frame-consumer task and the polling scenario.
final class Box<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var v: T
    init(_ v: T) { self.v = v }
    var value: T { lock.lock(); defer { lock.unlock() }; return v }
    func update(_ f: (inout T) -> Void) { lock.lock(); f(&v); lock.unlock() }
}

typealias Frame = (hostTime: UInt64, image: CGImage)

/// Every app the harness has launched and not yet terminated, so a signal handler can clean up.
public enum ActiveLaunches {
    private static let box = Box<[LaunchedApp]>([])
    static func add(_ l: LaunchedApp) { box.update { $0.append(l) } }
    static func remove(_ l: LaunchedApp) { box.update { $0.removeAll { $0.pid == l.pid && $0.startTime == l.startTime } } }
    public static var current: [LaunchedApp] { box.value }
    /// Terminates (via `Launcher.terminate`, PID-reuse guarded) every app still registered.
    public static func terminateAll() async {
        for l in box.value { await Launcher.terminate(l); remove(l) }
    }
}

/// Collects the `frame-timing.json` files of the Alloy launches made while `--attribute` is on. Carried to
/// `Harness.withApp` as a task-local so no scenario signature changes; absent means nothing about a launch changes.
public final class AttributionCollector: @unchecked Sendable {
    @TaskLocal static var current: AttributionCollector?
    private let files = Box<[Data]>([])
    public init() {}
    func add(_ d: Data) { files.update { $0.append(d) } }
    /// Notes over every launch collected so far; empty when nothing decoded.
    public var notes: [String] { files.value.flatMap { FrameTimingSummary.notes(from: $0) } }
    /// Runs `body` with this collector active for Alloy launches inside it.
    public func collecting<T>(_ body: () async -> T) async -> T {
        await Self.$current.withValue(self) { await body() }
    }
}

enum CaptureMode {
    case none
    /// Window capture, started once the main window is found.
    case window
    /// Application-scoped capture started right after launch; the handler is installed before the window
    /// is looked for, so no frame is missed (return false to stop consuming).
    case app(@Sendable (Frame) -> Bool)
}

/// A launched app with an optional running capture. Cleanup is guaranteed by `withApp`.
final class AppProbe: @unchecked Sendable {
    let launched: LaunchedApp
    var windowID: CGWindowID?
    var windowFrame: CGRect = .zero
    /// Where scroll events go; set from `TargetApp.scrollPoint` once the window is found.
    var scrollPoint: CGPoint?
    var capture: WindowCapture?
    private var tasks: [Task<Void, Never>] = []
    init(launched: LaunchedApp) { self.launched = launched }
    func consume(_ handler: @escaping @Sendable (Frame) -> Bool) async {
        guard let capture else { return }
        let stream = await capture.frames()
        tasks.append(Task { for await f in stream { if !handler(f) { break } } })
    }
    func finish() async {
        await capture?.stop()
        for t in tasks { await t.value }
        tasks = []
    }
    var droppedFrames: Int { capture?.drops.value ?? 0 }
    var captureHz: Int { get async { await capture?.effectiveHz ?? 0 } }
    var captureHzFromDisplay: Bool { get async { await capture?.hzFromDisplay ?? true } }
    var windowCenter: CGPoint { CGPoint(x: windowFrame.midX, y: windowFrame.midY) }
    var scrollTarget: CGPoint { scrollPoint ?? windowCenter }
}

enum Harness {
    /// Launches the app, waits for its main window (failing after `windowTimeout`), runs the body, and always
    /// terminates the launched tree and stops the capture.
    static func withApp<T>(_ app: TargetApp, file: String?, capture: CaptureMode, windowTimeout: Duration,
                           _ body: (AppProbe) async throws -> T) async throws -> T {
        let staged = try file.map { try Staging.stage($0) }
        let l: LaunchedApp
        let collector = app.id == "alloy" ? AttributionCollector.current : nil
        do {
            l = try Launcher.launch(app, file: staged?.file,
                                    extraEnvironment: collector == nil ? [:] : FrameTimingSummary.environment)
        } catch { staged?.remove(); throw error }
        ActiveLaunches.add(l)
        let probe = AppProbe(launched: l)
        func cleanup() async {
            await probe.finish()
            let timing = await Launcher.terminate(l, collecting: collector == nil ? nil : FrameTimingSummary.fileName)
            if let timing { collector?.add(timing) }
            ActiveLaunches.remove(l)
            staged?.remove()
        }
        let noWindow = { (why: any Error) in
            ScenarioFailure("no window within \(windowTimeout.components.seconds) s (\(why)); app terminated")
        }
        do {
            if case .app(let handler) = capture {
                let c = WindowCapture(pid: l.pid, fps: 60)
                do { try await c.start(timeout: windowTimeout) } catch {
                    await c.stop()
                    if case CaptureError.appNotFound = error { throw noWindow(error) }
                    throw ScenarioFailure("capture start failed: \(error)")
                }
                probe.capture = c
                await probe.consume(handler)
            }
            do {
                let w = try await Windows.waitForMainWindow(pid: l.pid, timeout: windowTimeout)
                probe.windowID = w.windowID; probe.windowFrame = w.frame; probe.scrollPoint = app.scrollPoint(w.frame)
            } catch { throw noWindow(error) }
            if case .window = capture, let id = probe.windowID {
                let c = WindowCapture(windowID: id, fps: 60)
                do { try await c.start() } catch { await c.stop(); throw error }
                probe.capture = c
            }
            let r = try await body(probe)
            await cleanup()
            return r
        } catch {
            let annotated = Harness.annotated(error, launchedPid: l.pid)   // while the app's own windows still exist
            await cleanup()
            throw annotated
        }
    }

    /// Name of another app's window currently covering the target area, ignoring the launched tree.
    static func coveringAppName(launchedPid: pid_t) -> String? {
        WindowCover.current(launchedPids: [launchedPid]).first?.ownerName
    }

    /// A paint failure re-evaluates the cover check and, if a window now covers the target area, says so.
    static func annotated(_ error: any Error, launchedPid: pid_t) -> any Error {
        guard let f = error as? ScenarioFailure, WindowCover.isPaintFailure(f.description) else { return error }
        return ScenarioFailure(WindowCover.annotate(f.description, covers: WindowCover.current(launchedPids: [launchedPid])))
    }

    static func poll(timeout: Duration, interval: Duration = .milliseconds(10), _ cond: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if cond() { return true }
            try? await Task.sleep(for: interval)
        }
        return cond()
    }

    /// First frame satisfying a predicate (application-scoped capture; used by the memory scenario).
    struct Hit: Sendable { var hostTime: UInt64? }

    private static func handler(_ hit: Box<Hit>, _ pred: @escaping @Sendable (FrameDiff.AppFrame) -> Bool) -> @Sendable (Frame) -> Bool {
        { f in
            let a = FrameDiff.analyzeAppFrame(f.image)
            if a.bounds != nil, pred(a) { hit.update { $0.hostTime = f.hostTime }; return false }
            return true
        }
    }

    /// App-capture handler recording the first frame where text rows cover >= 30 % of the app's window height.
    static func textPaintedHandler(_ hit: Box<Hit>) -> @Sendable (Frame) -> Bool { handler(hit) { $0.textFraction >= 0.3 } }

    static func await_(_ hit: Box<Hit>, timeout: Duration, what: String) async throws -> UInt64 {
        guard await poll(timeout: timeout, { hit.value.hostTime != nil }), let v = hit.value.hostTime else {
            throw ScenarioFailure("\(what) within \(timeout.components.seconds) s")
        }
        return v
    }

    /// Window-capture only: waits for the first non-blank frame.
    static func firstVisible(_ p: AppProbe, timeout: Duration) async throws -> UInt64 {
        let t = Box<UInt64?>(nil)
        await p.consume { f in
            if !FrameDiff.isBlank(f.image) { t.update { $0 = f.hostTime }; return false }
            return true
        }
        guard await poll(timeout: timeout, { t.value != nil }), let v = t.value else {
            throw ScenarioFailure("no non-blank frame within \(timeout.components.seconds) s")
        }
        return v
    }

    static let systemWindowOwners: Set<String> = ["Dock", "Window Server", "SystemUIServer", "Control Center", "Notification Center", "Screenshot"]

    /// A covering window that does not count as an obstruction: fully transparent, or a high-level window
    /// (menu bar, Dock, notifications) owned by a system process. Any other app's window always counts.
    static func ignorableCover(ownerName: String?, layer: Int, alpha: Double) -> Bool {
        if alpha == 0 { return true }
        guard layer != 0, let ownerName else { return false }
        return systemWindowOwners.contains(ownerName)
    }

    /// Scroll safety: the frontmost app and the topmost layer-0 window at `point` must both belong to the
    /// launched app's process tree, otherwise session-tap scroll events would hit someone else's window.
    static func targetIsSafe(_ p: AppProbe, at point: CGPoint) -> Bool {
        let tree = Set(ProcessTree.descendants(of: p.launched.pid))
        return pointIsSafe(point, frontPid: NSWorkspace.shared.frontmostApplication?.processIdentifier, tree: tree,
                           windows: WindowCover.onScreenWindows().filter { $0.layer >= 0 })
    }

    /// Pure core of the guard. `windows` are on-screen windows front to back; the first one that really covers
    /// `point` decides. Refuses when unsure (frontmost app outside `tree`, no window at the point, or another app on top).
    static func pointIsSafe(_ point: CGPoint, frontPid: pid_t?, tree: Set<pid_t>, windows: [WindowDescriptor]) -> Bool {
        guard let frontPid, tree.contains(frontPid) else { return false }
        for w in windows where w.bounds.contains(point) {
            if ignorableCover(ownerName: w.ownerName, layer: w.layer, alpha: w.alpha) { continue }
            return tree.contains(w.pid)   // any other app's window (any layer) covering the point is unsafe
        }
        return false
    }

}

public enum Probe {
    public static func refreshHz() -> Double {
        let id = CGMainDisplayID()
        let hz = CGDisplayCopyDisplayMode(id)?.refreshRate ?? 0
        return hz > 0 ? hz : 60
    }
    public static func scale() -> Double {
        let id = CGMainDisplayID()
        guard let m = CGDisplayCopyDisplayMode(id), m.width > 0 else { return 1 }
        return Double(m.pixelWidth) / Double(m.width)
    }
}
