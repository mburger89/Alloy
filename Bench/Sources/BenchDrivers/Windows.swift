import CoreGraphics
import Foundation
import BenchCore

public enum WindowError: Error, CustomStringConvertible {
    case timeout(pid_t, Duration)
    public var description: String {
        switch self { case .timeout(let p, let d): return "no main window for pid \(p) within \(d)" }
    }
}

public enum Windows {
    /// Polls for a layer-0, on-screen window of the pid (or its descendants) of at least 200x200.
    public static func waitForMainWindow(pid: pid_t, timeout: Duration) async throws -> (windowID: CGWindowID, frame: CGRect) {
        let deadline = ContinuousClock.now + timeout
        while true {
            if let w = findWindow(pid: pid) { return w }
            if ContinuousClock.now >= deadline { throw WindowError.timeout(pid, timeout) }
            try await Task.sleep(for: .milliseconds(50))
        }
    }

    static func findWindow(pid: pid_t) -> (windowID: CGWindowID, frame: CGRect)? {
        let owners = Set(ProcessTree.descendants(of: pid))
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] else { return nil }
        for w in list {
            guard let owner = w[kCGWindowOwnerPID as String] as? Int32, owners.contains(owner),
                  (w[kCGWindowLayer as String] as? Int) == 0,
                  let id = w[kCGWindowNumber as String] as? UInt32,
                  let bd = w[kCGWindowBounds as String] as? NSDictionary,
                  let r = CGRect(dictionaryRepresentation: bd as CFDictionary),
                  r.width >= 200, r.height >= 200 else { continue }
            return (id, r)
        }
        return nil
    }
}

/// Detects another app's window covering where target windows open. Pure over `WindowDescriptor`s; the
/// CGWindowList call is the thin adapter `WindowCover.onScreenWindows()`.
public struct WindowDescriptor: Sendable, Equatable {
    public var ownerName: String
    public var pid: Int32
    public var layer: Int
    public var bounds: CGRect
    public var alpha: Double
    public init(ownerName: String, pid: Int32, layer: Int, bounds: CGRect, alpha: Double = 1) {
        self.ownerName = ownerName; self.pid = pid; self.layer = layer; self.bounds = bounds; self.alpha = alpha
    }
}

public enum WindowCover {
    public struct Cover: Sendable, Equatable {
        public var ownerName: String
        public var pid: Int32
        /// Fraction (0...1) of the central region this window covers.
        public var fraction: Double
    }

    /// Share of the display (each axis) forming the central region where target windows open.
    public static let regionShare = 0.6
    /// A window covering more than this fraction of the central region is an obstruction.
    public static let threshold = 0.10

    public static func centralRegion(of display: CGRect) -> CGRect {
        let w = display.width * regionShare, h = display.height * regionShare
        return CGRect(x: display.midX - w / 2, y: display.midY - h / 2, width: w, height: h)
    }

    /// Normal-layer, visible windows of processes outside `excluding` that cover more than 10 % of the central
    /// 60 % x 60 % region of `display`, largest first. The harness's own terminal is not exempt.
    public static func covers(windows: [WindowDescriptor], display: CGRect, excluding: Set<Int32> = []) -> [Cover] {
        let region = centralRegion(of: display)
        guard region.width > 0, region.height > 0 else { return [] }
        let area = region.width * region.height
        var byPid: [Int32: Cover] = [:]
        for w in windows where w.layer == 0 && w.alpha > 0 && !excluding.contains(w.pid) {
            let i = w.bounds.intersection(region)
            guard !i.isNull, i.width > 0, i.height > 0 else { continue }
            let f = i.width * i.height / area
            guard f > threshold else { continue }
            if let c = byPid[w.pid], c.fraction >= f { continue }
            byPid[w.pid] = Cover(ownerName: w.ownerName, pid: w.pid, fraction: f)
        }
        return byPid.values.sorted { $0.fraction > $1.fraction }
    }

    /// Refusal text for the largest cover; nil when nothing covers.
    public static func refusalMessage(_ covers: [Cover], targetName: String) -> String? {
        guard let c = covers.first else { return nil }
        return String(format: "%@ has a window covering %.0f%% of the central area of the main display where %@ windows open. "
                      + "Move or minimize it (the harness never moves other apps' windows).", c.ownerName, c.fraction * 100, targetName)
    }

    /// Run failures that a covering window can explain.
    public static func isPaintFailure(_ reason: String) -> Bool {
        ["not painted", "no frame change", "fewer than 2 changed frames", "no paint detected", "no non-blank frame"]
            .contains { reason.contains($0) }
    }

    /// `reason` with " (covered by <app>)" appended when it is a paint failure and `covers` is non-empty.
    public static func annotate(_ reason: String, covers: [Cover]) -> String {
        guard isPaintFailure(reason), let c = covers.first, !reason.contains("covered by") else { return reason }
        return reason + " (covered by \(c.ownerName))"
    }

    /// Adapter: on-screen windows in global top-left coordinates, front to back.
    public static func onScreenWindows() -> [WindowDescriptor] {
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
        return list.compactMap { w in
            guard let pid = w[kCGWindowOwnerPID as String] as? Int32,
                  let bd = w[kCGWindowBounds as String] as? NSDictionary,
                  let r = CGRect(dictionaryRepresentation: bd as CFDictionary) else { return nil }
            return WindowDescriptor(ownerName: w[kCGWindowOwnerName as String] as? String ?? "pid \(pid)", pid: pid,
                                    layer: w[kCGWindowLayer as String] as? Int ?? 0, bounds: r,
                                    alpha: w[kCGWindowAlpha as String] as? Double ?? 1)
        }
    }

    /// Covers of the main display now, ignoring the processes (and descendants) in `launchedPids`.
    public static func current(launchedPids: [pid_t] = []) -> [Cover] {
        let own = Set(launchedPids.flatMap { ProcessTree.descendants(of: $0) })
        return covers(windows: onScreenWindows(), display: CGDisplayBounds(CGMainDisplayID()), excluding: own)
    }
}
