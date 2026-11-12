import Foundation

public enum BenchPaths {
    /// `<repo>/Bench/<leaf>`, where `<repo>` is the nearest directory at or above `cwd` that holds
    /// `Bench/Package.swift`. Falls back to the relative `Bench/<leaf>` when there is none.
    public static func defaultDirectory(_ leaf: String, cwd: String) -> String {
        var dir = URL(fileURLWithPath: cwd).standardizedFileURL.path
        while true {
            if FileManager.default.fileExists(atPath: dir + "/Bench/Package.swift") {
                return (dir == "/" ? "" : dir) + "/Bench/" + leaf
            }
            let parent = (dir as NSString).deletingLastPathComponent
            if parent == dir || parent.isEmpty { return "Bench/" + leaf }
            dir = parent
        }
    }
}
