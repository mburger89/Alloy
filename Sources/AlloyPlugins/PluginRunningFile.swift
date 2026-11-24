import Foundation

/// The pid file of running plugin process groups, read at launch to kill groups a crashed Alloy left behind.
public enum PluginRunningFile {
    public struct Entry: Codable, Equatable, Sendable {
        public var id: String
        public var pid: Int32
        public var start: Double
        public init(id: String, pid: Int32, start: Double) {
            self.id = id
            self.pid = pid
            self.start = start
        }
    }

    public static func read(_ url: URL) -> [Entry] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        return (try? JSONDecoder().decode([Entry].self, from: data)) ?? []
    }

    public static func write(_ entries: [Entry], to url: URL) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(entries) else { return }
        try? data.write(to: url, options: .atomic)
    }
}
