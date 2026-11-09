import AppKit
import CoreMedia
import CoreGraphics
import ScreenCaptureKit
import VideoToolbox

public enum CaptureError: Error, CustomStringConvertible {
    case windowNotFound(CGWindowID)
    case appNotFound(pid_t)
    public var description: String {
        switch self {
        case .windowNotFound(let id): return "ScreenCaptureKit cannot see window \(id)"
        case .appNotFound(let pid): return "ScreenCaptureKit cannot see an application with pid \(pid)"
        }
    }
}

/// Counts frames the capture buffer (`bufferingNewest`) evicted because the consumer fell behind.
public final class DropCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    public init() {}
    public var value: Int { lock.lock(); defer { lock.unlock() }; return n }
    public func record(_ r: AsyncStream<(hostTime: UInt64, image: CGImage)>.Continuation.YieldResult) {
        if case .dropped = r { lock.lock(); n += 1; lock.unlock() }
    }
}

private final class FrameSink: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    let continuation: AsyncStream<(hostTime: UInt64, image: CGImage)>.Continuation
    private let lock = NSLock()
    private var _error: Error?
    var error: Error? { lock.lock(); defer { lock.unlock() }; return _error }

    /// The stream died (window closed, app crashed): record why and end `frames()`.
    func stream(_ stream: SCStream, didStopWithError error: Error) {
        lock.lock(); _error = error; lock.unlock()
        continuation.finish()
    }

    let drops: DropCounter
    init(_ c: AsyncStream<(hostTime: UInt64, image: CGImage)>.Continuation, drops: DropCounter) { continuation = c; self.drops = drops }

    func stream(_ stream: SCStream, didOutputSampleBuffer sb: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sb.isValid,
              let atts = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let raw = atts.first?[.status] as? Int, SCFrameStatus(rawValue: raw) == .complete,
              let pb = CMSampleBufferGetImageBuffer(sb) else { return }
        var img: CGImage?
        VTCreateCGImageFromCVPixelBuffer(pb, options: nil, imageOut: &img)
        guard let image = img else { return }
        // Convert the sample's timestamp to mach host time (same units as mach_absolute_time).
        // SCStream timestamps are already on the host time clock.
        let hostTime = CMClockConvertHostTimeToSystemUnits(CMSampleBufferGetPresentationTimeStamp(sb))
        drops.record(continuation.yield((hostTime: hostTime, image: image)))
    }
}

public actor WindowCapture {
    private let windowID: CGWindowID?
    private let pid: pid_t?
    private let fps: Int
    /// Frames evicted from the capture buffer so far (the consumer fell behind).
    public nonisolated let drops = DropCounter()
    private var stream: SCStream?
    private var sink: FrameSink?
    private var queue: DispatchQueue?
    /// Capture rate actually requested: the display's real refresh rate (fps is only a fallback floor).
    public private(set) var effectiveHz = 0
    /// False when the OS did not report a refresh rate and `effectiveHz` is the fallback.
    public private(set) var hzFromDisplay = true
    /// mach_absolute_time at which `startCapture` returned (frames can flow from here on).
    public private(set) var readyAt: UInt64 = 0
    private let pair = AsyncStream.makeStream(of: (hostTime: UInt64, image: CGImage).self,
                                              bufferingPolicy: .bufferingNewest(64))

    public init(windowID: CGWindowID, fps: Int) { self.windowID = windowID; self.pid = nil; self.fps = fps }

    /// Application-scoped capture: all on-screen windows of `pid`, composited on a transparent display-sized
    /// frame. Can start before the app has created a window (waits for the app to appear).
    public init(pid: pid_t, fps: Int) { self.windowID = nil; self.pid = pid; self.fps = fps }

    /// Display-scoped capture of the whole main display (1x, points), usable before the app is launched.
    public init(mainDisplayFps fps: Int) { self.windowID = nil; self.pid = nil; self.fps = fps }

    public func start(timeout: Duration = .seconds(30)) async throws {
        let filter: SCContentFilter
        let cfg = SCStreamConfiguration()
        var display: CGDirectDisplayID = 0
        if let windowID {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            guard let window = content.windows.first(where: { $0.windowID == windowID }) else {
                throw CaptureError.windowNotFound(windowID)
            }
            filter = SCContentFilter(desktopIndependentWindow: window)
            var displayCount: UInt32 = 0
            CGGetDisplaysWithRect(window.frame, 1, &display, &displayCount)
            if displayCount == 0 { display = CGMainDisplayID() }
            let scale = CGFloat(filter.pointPixelScale)
            cfg.width = Int(filter.contentRect.width * scale)
            cfg.height = Int(filter.contentRect.height * scale)
        } else if pid == nil {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            guard let d = content.displays.first(where: { $0.displayID == CGMainDisplayID() }) ?? content.displays.first else {
                throw CaptureError.appNotFound(0)
            }
            filter = SCContentFilter(display: d, excludingWindows: [])
            display = d.displayID
            cfg.width = d.width; cfg.height = d.height
        } else {
            let deadline = ContinuousClock.now + timeout
            var found: (SCRunningApplication, SCDisplay)?
            while found == nil {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
                if let app = content.applications.first(where: { $0.processID == pid }),
                   let d = content.displays.first(where: { $0.displayID == CGMainDisplayID() }) ?? content.displays.first {
                    found = (app, d)
                } else if ContinuousClock.now >= deadline {
                    throw CaptureError.appNotFound(pid ?? 0)
                } else {
                    try await Task.sleep(for: .milliseconds(15))
                }
            }
            let (app, d) = found!
            filter = SCContentFilter(display: d, including: [app], exceptingWindows: [])
            display = d.displayID
            cfg.width = d.width; cfg.height = d.height   // points: 1x keeps per-frame analysis cheap
        }
        let hz = CGDisplayCopyDisplayMode(display)?.refreshRate ?? 0
        hzFromDisplay = hz > 0
        effectiveHz = hz > 0 ? Int(hz.rounded()) : max(fps, 60)
        cfg.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(effectiveHz))
        cfg.queueDepth = 8
        cfg.pixelFormat = kCVPixelFormatType_32BGRA
        cfg.showsCursor = false
        let sink = FrameSink(pair.continuation, drops: drops)
        let s = SCStream(filter: filter, configuration: cfg, delegate: sink)
        let q = DispatchQueue(label: "bench.capture", qos: .userInteractive)
        try s.addStreamOutput(sink, type: .screen, sampleHandlerQueue: q)
        try await s.startCapture()
        readyAt = mach_absolute_time()
        self.stream = s; self.sink = sink; self.queue = q
    }

    /// Why the stream ended on its own (nil if it has not, or was stopped normally).
    public var stopError: Error? { sink?.error }

    public func stop() async {
        if let s = stream { try? await s.stopCapture() }
        stream = nil
        pair.continuation.finish()
    }

    public func frames() -> AsyncStream<(hostTime: UInt64, image: CGImage)> { pair.stream }
}
