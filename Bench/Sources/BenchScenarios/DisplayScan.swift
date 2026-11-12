import CoreGraphics
import Darwin
import Foundation
import BenchCore
import BenchDrivers

/// What a display-capture scan is looking for in the launched app's window region.
enum ScanMode: Sendable { case startup, textPainted }

/// Scans a stream of full-display frames (captured *before* the launch, so there is no capture-ready floor)
/// for the first frame in which the launched app's window has painted. Pure state machine: feed it frames
/// with `ingest`, window sightings with `windowSeen`; unit-tested with synthetic images.
///
/// All analysis runs on an INNER region of the window, not the whole window rectangle: the sides and bottom are
/// inset by `sideInset` pt (default 26 pt, covering the largest modern macOS window corner radius, never less
/// than 16 pt) and the top by `topInset` pt (default 44 pt: a 28 pt titlebar plus margin for a toolbar). That
/// keeps desktop pixels showing in rounded corners, the translucent titlebar/toolbar material, shadows and the
/// window-open animation out of the decision.
/// - startup: first frame at/after launch whose inner region is non-blank (not one uniform colour) AND differs
///   significantly from the baseline's inner region (caret filter applied, change covering >= 1 % of it).
/// - textPainted: same significance requirement AND rows whose glyph-transition pattern differs from the same
///   rows of the baseline cover >= 30 % of the inner height (text already behind the window never counts).
/// - invalid: the baseline inner region changed in a frame that precedes the window's first on-screen sighting
///   by more than `slack` (the user's own screen activity), so the sample cannot be trusted.
final class DisplayScan: @unchecked Sendable {
    enum Result: Sendable, Equatable { case hit(UInt64), invalid(String) }

    private let lock = NSLock()
    private let mode: ScanMode
    private let slack: UInt64          // mach ticks
    private let displayOrigin: CGPoint
    private let displayWidth: Double
    private let sideInset: Double, topInset: Double   // points
    private let maxRingFrames: Int
    private let ringAge: UInt64        // mach ticks

    private var latest: CGImage?
    private var baseline: CGImage?
    private var baselineCrop: (region: PixelRect, px: FrameDiff.Pixels?, sigs: FrameDiff.RowSignatures?)?   // rendered once per region
    private var frozen = false
    private var launchedAt: UInt64?
    private var rect: CGRect?
    private var detectedAt: UInt64?
    private var ring: [Frame] = []
    private var _result: Result?

    init(mode: ScanMode, displayOrigin: CGPoint = .zero, displayWidth: Double? = nil, slackMs: Double = 150, ringMs: Double = 800,
         maxRingFrames: Int = 64, sideInset: Double = 26, topInset: Double = 44) {
        self.mode = mode; self.displayOrigin = displayOrigin
        self.displayWidth = displayWidth ?? CGDisplayBounds(CGMainDisplayID()).width; self.maxRingFrames = maxRingFrames
        self.sideInset = sideInset; self.topInset = topInset
        slack = DisplayScan.ticks(ms: slackMs); ringAge = DisplayScan.ticks(ms: ringMs)
    }

    static func ticks(ms: Double) -> UInt64 {
        var tb = mach_timebase_info_data_t(); mach_timebase_info(&tb)
        return UInt64(ms * 1e6 * Double(tb.denom) / Double(tb.numer))
    }

    var result: Result? { lock.lock(); defer { lock.unlock() }; return _result }
    var hasBaseline: Bool { lock.lock(); defer { lock.unlock() }; return latest != nil }
    var windowDetectedAt: UInt64? { lock.lock(); defer { lock.unlock() }; return detectedAt }

    /// Freezes the baseline at the newest frame seen so far; call right before launching. Frames delivered from now
    /// on are buffered until `launched(at:)` supplies the real launch time.
    func freezeBaseline() {
        lock.lock(); defer { lock.unlock() }
        baseline = latest; baselineCrop = nil; frozen = true
    }

    /// Supplies the real launch time; buffered frames older than it are dropped, so no hit can predate the launch.
    func launched(at t: UInt64) {
        lock.lock(); defer { lock.unlock() }
        launchedAt = t
        ring.removeAll { $0.hostTime < t }
        drain()
    }

    func windowSeen(rect r: CGRect, at t: UInt64) {
        lock.lock(); defer { lock.unlock() }
        if detectedAt == nil { detectedAt = t }
        if _result == nil { rect = r }
        drain()   // an idle display delivers no further frames, so buffered ones must be settled here too
    }

    /// Feed every captured frame; returns false when the scan is finished.
    func ingest(_ f: Frame) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard frozen else { latest = f.image; return true }
        guard _result == nil else { return false }
        if let l = launchedAt, f.hostTime < l { return true }
        ring.append(f)
        while ring.count > maxRingFrames || (ring.count > 1 && f.hostTime &- ring[0].hostTime > ringAge) { ring.removeFirst() }
        drain()
        return _result == nil
    }

    /// With the window known, settles the buffered frames in order. Caller holds the lock.
    private func drain() {
        guard _result == nil, frozen, launchedAt != nil, rect != nil, let detected = detectedAt, !ring.isEmpty else { return }
        let pending = ring
        ring = []
        let early = pending.filter { $0.hostTime &+ slack < detected }
        // Only the newest pre-window frame is compared (a persisting change); evaluating all would stall the stream.
        if let e = early.last, let c = crop(e.image), let b = significantChange(c.cur, c.base) {
            _result = .invalid("screen region changed before window existed (changed \(b.width)x\(b.height) px at \(b.x),\(b.y); frame \(Int(Double(detected &- e.hostTime) / Double(DisplayScan.ticks(ms: 1)))) ms before window)")
            return
        }
        for p in pending where p.hostTime &+ slack >= detected {
            if hit(p.image) { _result = .hit(p.hostTime); return }
        }
    }

    /// The inner analysis region in image pixels (see the type comment).
    private func innerRegion(_ image: CGImage) -> PixelRect? {
        guard let r = rect else { return nil }
        let scale = displayWidth > 0 ? Double(image.width) / displayWidth : 1
        let x = (r.minX - displayOrigin.x + sideInset) * scale, y = (r.minY - displayOrigin.y + topInset) * scale
        let w = (r.width - 2 * sideInset) * scale, h = (r.height - topInset - sideInset) * scale
        let pr = PixelRect(x: Int(x), y: Int(y), width: Int(w), height: Int(h))
        return pr.width > 0 && pr.height > 0 ? pr : nil
    }

    /// Crops the frame to the inner region (one render) and returns it with the cached baseline crop for that region.
    private func crop(_ image: CGImage) -> (cur: FrameDiff.Pixels, base: FrameDiff.Pixels?, sigs: FrameDiff.RowSignatures?)? {
        guard let region = innerRegion(image), let cur = FrameDiff.crop(image, to: region) else { return nil }
        var base: FrameDiff.Pixels?
        var sigs: FrameDiff.RowSignatures?
        if let cached = baselineCrop, cached.region == region { base = cached.px; sigs = cached.sigs }
        else if let b = baseline {
            base = FrameDiff.crop(b, to: region)
            sigs = base.map { FrameDiff.rowSignatures($0) }   // computed once per region, reused for every frame
            baselineCrop = (region, base, sigs)
        }
        return (cur, base, sigs)
    }

    private func significantChange(_ cur: FrameDiff.Pixels, _ base: FrameDiff.Pixels?) -> PixelRect? {
        guard let base, let b = FrameDiff.changedBounds(base, cur), FrameDiff.isContentChange(b) else { return nil }
        // Ignore cursor/clock-sized changes (a terminal block caret blinking under the future window is 8x17 px);
        // only a change covering >= 1 % of the inner region counts.
        return b.width * b.height * 100 >= cur.width * cur.height ? b : nil
    }

    private func hit(_ image: CGImage) -> Bool {
        guard let c = crop(image) else { return false }
        // Both modes need a significant change against the pre-launch baseline, so text or blinking carets that
        // were already on screen under the future window (the user's terminal) can never count as the app painting.
        if c.base != nil, significantChange(c.cur, c.base) == nil { return false }
        switch mode {
        case .startup: return !FrameDiff.isBlank(c.cur)
        case .textPainted: return FrameDiff.textRowFraction(c.cur, differingFrom: c.sigs) >= 0.3
        }
    }
}

/// Polls CGWindowList every 5 ms for the launched tree's largest on-screen layer-0 window.
enum WindowPoller {
    static func largestWindow(inTreeOf pid: pid_t) -> CGRect? {
        let tree = Set(ProcessTree.descendants(of: pid))
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        var best: CGRect?
        for w in list {
            guard (w[kCGWindowLayer as String] as? Int) == 0,
                  let owner = w[kCGWindowOwnerPID as String] as? Int32, tree.contains(owner),
                  (w[kCGWindowAlpha as String] as? Double ?? 1) > 0,
                  let bd = w[kCGWindowBounds as String] as? [String: Any],
                  let r = CGRect(dictionaryRepresentation: bd as CFDictionary), r.width >= 50, r.height >= 50 else { continue }
            if best == nil || r.width * r.height > best!.width * best!.height { best = r }
        }
        return best
    }
}

extension Harness {
    /// Pre-launch display capture: start capturing the main display, grab a baseline, launch, poll CGWindowList
    /// for the window, and scan frames. Returns (milliseconds from launch to hit, milliseconds from launch to window on screen).
    static func measureOnDisplay(_ app: TargetApp, file: String, mode: ScanMode, timeout: Duration) async throws -> (hitMs: Double, windowMs: Double) {
        if let session = TraceSession.current, let metric = TraceSession.metric,
           session.shouldTrace(app: app.id, metric: metric) {
            session.addNote(TraceSession.unsupportedNote(app: app.displayName, metric: metric), app: app.id, metric: metric)
        }
        let staged = try Staging.stage(file)
        defer { staged.remove() }
        let cap = WindowCapture(mainDisplayFps: 60)
        do { try await cap.start() } catch { await cap.stop(); throw ScenarioFailure("capture start failed: \(error)") }
        let scan = DisplayScan(mode: mode, displayOrigin: CGDisplayBounds(CGMainDisplayID()).origin)
        let stream = await cap.frames()
        let dropsAtHit = Box<Int>(0)
        let consumer = Task { for await f in stream { if !scan.ingest(f) { dropsAtHit.update { $0 = cap.drops.value }; break } } }
        func stopCapture() async { await cap.stop(); await consumer.value }
        guard await poll(timeout: .seconds(3), { scan.hasBaseline }) else {
            await stopCapture(); throw ScenarioFailure("no baseline frame from display capture within 3 s")
        }
        let l: LaunchedApp
        do {
            scan.freezeBaseline()   // frames from here on are buffered; those older than the real launch time are dropped
            l = try Launcher.launch(app, file: staged.file)
            scan.launched(at: l.launchedAt)
        } catch { await stopCapture(); throw error }
        ActiveLaunches.add(l)
        // The window cannot exist before the start of the last poll that did not see it, so that is the scan's
        // "window existed" bound; CGWindowList itself lags a paint by tens of ms, so detection time is only reported.
        let foundAt = Box<UInt64?>(nil)
        let poller = Task { () -> Void in
            var lastMissStart = mach_absolute_time()
            while !Task.isCancelled {
                let start = mach_absolute_time()
                if let r = WindowPoller.largestWindow(inTreeOf: l.pid) {
                    if foundAt.value == nil { foundAt.update { $0 = mach_absolute_time() } }
                    scan.windowSeen(rect: r, at: lastMissStart)
                } else { lastMissStart = start }
                try? await Task.sleep(for: .milliseconds(5))
            }
        }
        func cleanup() async {
            poller.cancel(); await poller.value
            await stopCapture()
            await Launcher.terminate(l)
            ActiveLaunches.remove(l)
        }
        let ok = await poll(timeout: timeout, interval: .milliseconds(5)) { scan.result != nil }
        let windowAt = foundAt.value
        let result = scan.result
        let covers = ok ? [] : WindowCover.current(launchedPids: [l.pid])   // before cleanup, so the app's own windows are excluded
        await cleanup()
        guard ok, let result else {
            throw ScenarioFailure(WindowCover.annotate(windowAt == nil ? "no window within \(timeout.components.seconds) s (app terminated)"
                                  : "window on screen but no paint detected within \(timeout.components.seconds) s", covers: covers))
        }
        switch result {
        case .invalid(let why): throw ScenarioFailure(why)
        case .hit(let t):
            if let f = droppedFramesFailure(dropsAtHit.value) { throw f }
            guard t >= l.launchedAt else { throw ScenarioFailure("internal error: paint frame predates launch") }
            return (ms(t &- l.launchedAt), windowAt.map { ms($0 &- l.launchedAt) } ?? 0)
        }
    }
}

/// A frame dropped by the capture buffer before the hit may have been the true first-painted frame, so the run
/// cannot be trusted.
func droppedFramesFailure(_ dropped: Int) -> ScenarioFailure? {
    dropped > 0 ? ScenarioFailure("capture dropped frames (\(dropped) before the hit)") : nil
}
