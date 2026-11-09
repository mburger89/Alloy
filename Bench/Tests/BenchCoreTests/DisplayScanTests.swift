import Testing
import Foundation
import CoreGraphics
@testable import BenchCore
@testable import BenchScenarios

private func image(stripes rows: Int = 0, fill: UInt8? = nil, region: PixelRect = PixelRect(x: 20, y: 10, width: 100, height: 60)) -> CGImage {
    let w = 200, h = 100
    var d = [UInt8](repeating: 255, count: w * h * 4)
    func set(_ x: Int, _ y: Int, _ v: UInt8) { let i = (y * w + x) * 4; d[i] = v; d[i + 1] = v; d[i + 2] = v; d[i + 3] = 255 }
    for y in 0..<h { for x in 0..<w { set(x, y, 200) } }
    if let fill { for y in region.y..<(region.y + region.height) { for x in region.x..<(region.x + region.width) { set(x, y, fill) } } }
    for y in region.y..<(region.y + rows) { for x in stride(from: region.x, to: region.x + region.width, by: 2) { set(x, y, 0) } }
    return CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4,
                   space: CGColorSpaceCreateDeviceRGB(),
                   bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
                   provider: CGDataProvider(data: Data(d) as CFData)!, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
}

private func t(_ ms: Double) -> UInt64 { 1_000_000_000 + DisplayScan.ticks(ms: ms + 1_000) - DisplayScan.ticks(ms: 1_000) }
private let win = CGRect(x: 20, y: 10, width: 100, height: 60)

/// 4 pt insets keep the small synthetic frames (window 100x60 pt) meaningful; production uses 26 / 44 pt.
private func scan(_ mode: ScanMode, side: Double = 4, top: Double = 4) -> DisplayScan {
    DisplayScan(mode: mode, displayWidth: 200, sideInset: side, topInset: top)
}

private func primed(_ mode: ScanMode) -> DisplayScan {
    let s = scan(mode)
    #expect(s.ingest((hostTime: t(-50), image: image())))      // pre-launch baseline
    s.freezeBaseline(); s.launched(at: t(0))
    return s
}

@Suite struct DisplayScanTests {
    @Test func startupHitsFirstPaintedFrameAfterWindowAppears() {
        let s = primed(.startup)
        _ = s.ingest((hostTime: t(20), image: image()))
        s.windowSeen(rect: win, at: t(100))
        _ = s.ingest((hostTime: t(110), image: image(fill: 100)))     // blank (uniform) window: not yet painted
        #expect(s.result == nil)
        _ = s.ingest((hostTime: t(140), image: image(stripes: 60)))
        #expect(s.result == .hit(t(140)))
    }

    @Test func fastPainterHitsFrameBufferedBeforeDetection() {
        let s = primed(.startup)
        // The painted frame arrives before the poll sees the window (within slack): it must still count.
        _ = s.ingest((hostTime: t(95), image: image(stripes: 60)))
        s.windowSeen(rect: win, at: t(100))
        _ = s.ingest((hostTime: t(115), image: image(stripes: 60)))
        #expect(s.result == .hit(t(95)))
    }

    @Test func idleDisplayHitIsSettledByWindowSightingAlone() {
        let s = primed(.startup)
        _ = s.ingest((hostTime: t(95), image: image(stripes: 60)))   // last frame the idle display ever delivers
        s.windowSeen(rect: win, at: t(100))
        #expect(s.result == .hit(t(95)))
    }

    @Test func preexistingTextUnderTheWindowIsNotAHit() {
        // Text already in the baseline region (user's terminal) must not count as the app painting.
        let s = scan(.textPainted)
        _ = s.ingest((hostTime: t(-50), image: image(stripes: 60)))
        s.freezeBaseline(); s.launched(at: t(0))
        s.windowSeen(rect: win, at: t(100))
        _ = s.ingest((hostTime: t(120), image: image(stripes: 60)))
        #expect(s.result == nil)
    }

    @Test func screenChangeBeforeWindowExistsIsInvalid() {
        let s = primed(.startup)
        _ = s.ingest((hostTime: t(30), image: image(stripes: 60)))    // user activity in the future window region
        s.windowSeen(rect: win, at: t(400))
        _ = s.ingest((hostTime: t(420), image: image(stripes: 60)))
        guard case .invalid(let why)? = s.result else { Issue.record("expected invalid"); return }
        #expect(why.hasPrefix("screen region changed before window existed"))
    }

    @Test func unchangedRegionBeforeWindowIsFine() {
        let s = primed(.startup)
        _ = s.ingest((hostTime: t(30), image: image()))
        s.windowSeen(rect: win, at: t(400))
        _ = s.ingest((hostTime: t(420), image: image(stripes: 60)))
        #expect(s.result == .hit(t(420)))
    }

    @Test func framesBeforeLaunchAreIgnored() {
        let s = primed(.startup)
        s.windowSeen(rect: win, at: t(100))
        _ = s.ingest((hostTime: t(-10), image: image(stripes: 60)))
        #expect(s.result == nil)
    }

    @Test func textModeNeedsTextRows() {
        let s = primed(.textPainted)
        s.windowSeen(rect: win, at: t(100))
        _ = s.ingest((hostTime: t(110), image: image(stripes: 10)))   // 10 of 52 inset rows: below 30 %
        #expect(s.result == nil)
        _ = s.ingest((hostTime: t(130), image: image(stripes: 60)))
        #expect(s.result == .hit(t(130)))
    }

    @Test func frameBufferedBeforeLaunchTimeIsDroppedWhenLaunchIsStamped() {
        let s = scan(.startup)
        _ = s.ingest((hostTime: t(-50), image: image()))
        s.freezeBaseline()
        _ = s.ingest((hostTime: t(-5), image: image(stripes: 60)))    // after the baseline, before the real launch time
        s.launched(at: t(0))
        s.windowSeen(rect: win, at: t(100))
        #expect(s.result == nil)
        _ = s.ingest((hostTime: t(130), image: image(stripes: 60)))
        #expect(s.result == .hit(t(130)))
    }
}

// MARK: inner-region behaviour (synthetic 200x100 frames, window 100x60 at (20,10), 10 pt insets -> inner x30..110, y20..60)

private typealias Setter = (Int, Int, UInt8) -> Void
private func canvas(_ draw: (Setter) -> Void) -> CGImage {
    let w = 200, h = 100
    var d = [UInt8](repeating: 255, count: w * h * 4)
    let set: Setter = { x, y, v in guard x >= 0, y >= 0, x < w, y < h else { return }; let i = (y * w + x) * 4; d[i] = v; d[i + 1] = v; d[i + 2] = v; d[i + 3] = 255 }
    for y in 0..<h { for x in 0..<w { set(x, y, 200) } }
    draw(set)
    return CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4,
                   space: CGColorSpaceCreateDeviceRGB(),
                   bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
                   provider: CGDataProvider(data: Data(d) as CFData)!, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
}
private func fillWindow(_ set: Setter, _ v: UInt8 = 100) {
    for y in 10..<70 { for x in 20..<120 { set(x, y, v) } }
}
/// Glyph-like rows: alternating pixels every `step` columns over the window's inner rows.
private func text(_ set: Setter, step: Int = 2, x0: Int = 20, x1: Int = 120, y0: Int = 10, y1: Int = 70) {
    for y in y0..<y1 { for x in stride(from: x0, to: x1, by: step) { set(x, y, 0) } }
}
private func desktopText(_ set: Setter) { text(set, step: 2, x0: 0, x1: 200, y0: 0, y1: 100) }

@Suite struct InnerRegionScanTests {
    private func run(_ mode: ScanMode, baseline: CGImage, frames: [(Double, CGImage)]) -> DisplayScan {
        let s = scan(mode, side: 10, top: 10)
        _ = s.ingest((hostTime: t(-50), image: baseline))
        s.freezeBaseline(); s.launched(at: t(0))
        s.windowSeen(rect: win, at: t(100))
        for (ms, img) in frames { _ = s.ingest((hostTime: t(ms), image: img)) }
        return s
    }

    @Test(arguments: [ScanMode.startup, .textPainted])
    func desktopTextInBaselineWithUniformWindowOverItIsNotPainted(_ mode: ScanMode) {
        let base = canvas { desktopText($0) }
        let s = run(mode, baseline: base, frames: [(110, canvas { desktopText($0); fillWindow($0) })])
        #expect(s.result == nil)
    }

    @Test(arguments: [ScanMode.startup, .textPainted])
    func uniformWindowThenTextIsPaintedOnlyOnTheTextFrame(_ mode: ScanMode) {
        let base = canvas { _ in }
        let uniform = canvas { fillWindow($0) }
        let painted = canvas { fillWindow($0); text($0, step: 3, x0: 22, x1: 118, y0: 12, y1: 68) }
        let s = run(mode, baseline: base, frames: [(110, uniform), (120, uniform)])
        #expect(s.result == nil)
        _ = s.ingest((hostTime: t(160), image: painted))
        #expect(s.result == .hit(t(160)))
    }

    @Test(arguments: [ScanMode.startup, .textPainted])
    func desktopShowingInRoundedCornersIsNotCounted(_ mode: ScanMode) {
        // Uniform window whose 8x8 corners show striped desktop: only the outer ring differs, the inner region is flat.
        let base = canvas { _ in }
        let cornered = canvas { set in
            fillWindow(set)
            for (cx, cy) in [(20, 10), (112, 10), (20, 62), (112, 62)] {
                for y in cy..<(cy + 8) { for x in cx..<(cx + 8) { set(x, y, x % 2 == 0 ? 0 : 255) } }
            }
        }
        let s = run(mode, baseline: base, frames: [(110, cornered)])
        #expect(s.result == nil)
    }

    @Test func textBehindWindowThatIsUnchangedInsideDoesNotCount() {
        // Desktop text in the baseline, window frame shows the identical rows (translucent material): no text hit.
        let base = canvas { desktopText($0) }
        let s = run(.textPainted, baseline: base, frames: [(110, canvas { desktopText($0) }), (130, canvas { desktopText($0) })])
        #expect(s.result == nil)
    }
}

@Suite struct CoverWindowFilterTests {
    @Test func onlySystemOwnedHighLevelWindowsAreIgnored() {
        #expect(Harness.ignorableCover(ownerName: "Dock", layer: 20, alpha: 1))
        #expect(Harness.ignorableCover(ownerName: "Window Server", layer: 25, alpha: 1))
        #expect(Harness.ignorableCover(ownerName: "Notification Center", layer: 23, alpha: 1))
        #expect(Harness.ignorableCover(ownerName: "Screenshot", layer: 24, alpha: 1))   // screencaptureui overlay
        #expect(!Harness.ignorableCover(ownerName: "Zed", layer: 25, alpha: 1))          // other app, high level: still aborts
        #expect(!Harness.ignorableCover(ownerName: "Ghostty", layer: 3, alpha: 1))
        #expect(!Harness.ignorableCover(ownerName: "Dock", layer: 0, alpha: 1))
        #expect(!Harness.ignorableCover(ownerName: nil, layer: 8, alpha: 1))
        #expect(Harness.ignorableCover(ownerName: "Zed", layer: 0, alpha: 0))            // fully transparent
    }
}
