import Foundation

/// One frame's timing as the benchmark harness reads it. Nanoseconds, as integers.
public struct FrameRecord: Codable, Sendable, Equatable {
    /// "key" | "text" | "pointer" | "wheel" | "other", or nil for a frame no input caused.
    public var kind: String?
    /// Input received minus input timestamp: how long the event waited in the platform's queue.
    public var queueNs: UInt64?
    /// Paint end minus build start: MetalUI layout, prepaint and paint plus Alloy's body evaluation.
    public var buildNs: UInt64
    /// Commit minus paint end: encoding and submission.
    public var encodeNs: UInt64
    public var inputToCommitNs: UInt64?
    public var inputToPresentedNs: UInt64?

    public init(kind: String? = nil, queueNs: UInt64? = nil, buildNs: UInt64, encodeNs: UInt64,
                inputToCommitNs: UInt64? = nil, inputToPresentedNs: UInt64? = nil) {
        self.kind = kind
        self.queueNs = queueNs
        self.buildNs = buildNs
        self.encodeNs = encodeNs
        self.inputToCommitNs = inputToCommitNs
        self.inputToPresentedNs = inputToPresentedNs
    }
}

/// The `frame-timing.json` file Alloy writes into its data directory: `{"schemaVersion":1,"frames":[...]}`.
public enum FrameTimingDump {
    public static let fileName = "frame-timing.json"

    private struct File: Codable {
        var schemaVersion: Int
        var frames: [FrameRecord]
    }

    public static func encode(_ frames: [FrameRecord]) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(File(schemaVersion: 1, frames: frames))
    }

    public static func decode(_ data: Data) throws -> [FrameRecord] {
        try JSONDecoder().decode(File.self, from: data).frames
    }
}
