import Foundation

/// A per-run copy of a corpus file, alone in a fresh temporary directory. Apps open the copy (or its directory),
/// never `Bench/Corpus`, so the committed corpus cannot be modified and every app is handed the same single file.
struct Staged: Sendable {
    /// The fresh directory holding only the copy; nil when the input was not a file (passed through untouched).
    let directory: String?
    let file: String
    func remove() { if let d = directory { try? FileManager.default.removeItem(atPath: d) } }
}

enum Staging {
    /// Copies `source` into a new empty directory. A path that is not an existing file (the fixture app's
    /// "animate"/"static" modes) is passed through unchanged.
    static func stage(_ source: String) throws -> Staged {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: source, isDirectory: &isDir), !isDir.boolValue else {
            return Staged(directory: nil, file: source)
        }
        let dir = NSTemporaryDirectory() + "bench-corpus-\(getpid())-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let dest = dir + "/" + (source as NSString).lastPathComponent
        try FileManager.default.copyItem(atPath: source, toPath: dest)
        return Staged(directory: dir, file: dest)
    }
}
