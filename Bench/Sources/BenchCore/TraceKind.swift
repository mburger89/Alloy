import Foundation

/// What an Instruments trace records; each kind maps to one xctrace template.
public enum TraceKind: String, Codable, CaseIterable, Sendable {
    case time, allocations, hitches, gpu, concurrency

    public var template: String {
        switch self {
        case .time: return "Time Profiler"
        case .allocations: return "Allocations"
        case .hitches: return "Animation Hitches"
        case .gpu: return "Metal System Trace"
        case .concurrency: return "Swift Concurrency"
        }
    }
}
