import Foundation

/// Counts how often a component's `content` body is evaluated, so tests can assert that typing leaves the sidebar, the
/// screen and the chat column alone. Compiled out of release builds.
@MainActor
public enum BodyProbe {
    #if DEBUG
    public private(set) static var counts: [String: Int] = [:]
    #endif

    @inline(__always)
    public static func hit(_ name: String) {
        #if DEBUG
        counts[name, default: 0] += 1
        #endif
    }

    public static func count(_ name: String) -> Int {
        #if DEBUG
        counts[name, default: 0]
        #else
        0
        #endif
    }
}
