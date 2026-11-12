import AlloyCore
import Foundation
import MetalUI

/// Records MetalUI's frame timing when the benchmark asks for it, so a slow number can be blamed on Alloy or on
/// MetalUI. Off unless `ALLOY_FRAME_TIMING=1` and `ALLOY_DATA_DIR` are both set.
@MainActor
public enum FrameTimingRecorder {
    public static func record(_ s: FrameTimingSample) -> FrameRecord {
        let kind: String? = s.inputKind.map {
            switch $0 {
            case .key: "key"
            case .text: "text"
            case .pointer: "pointer"
            case .wheel: "wheel"
            case .other: "other"
            }
        }
        var queue: UInt64?
        if let stamp = s.inputTimestamp, let received = s.inputReceived {
            queue = received >= stamp ? received - stamp : 0
        }
        return FrameRecord(kind: kind, queueNs: queue,
                           buildNs: s.paintEnd >= s.buildStart ? s.paintEnd - s.buildStart : 0,
                           encodeNs: s.commit >= s.paintEnd ? s.commit - s.paintEnd : 0,
                           inputToCommitNs: s.inputToCommit, inputToPresentedNs: s.inputToPresented)
    }

    /// Sets `window.frameTiming` and returns the dump URL when the environment asks for it; otherwise nil.
    public static func install(on window: Window, environment: [String: String]) -> URL? {
        guard environment["ALLOY_FRAME_TIMING"] == "1", let dir = environment["ALLOY_DATA_DIR"], !dir.isEmpty else { return nil }
        window.frameTiming = FrameTiming(capacity: 8192)
        return URL(fileURLWithPath: dir, isDirectory: true).appendingPathComponent(FrameTimingDump.fileName)
    }

    public static func write(_ timing: FrameTiming, to url: URL) throws {
        try FrameTimingDump.encode(timing.samples.map(record)).write(to: url, options: .atomic)
    }
}
