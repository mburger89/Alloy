import Foundation

/// Throwaway files and folders under `$TMPDIR` that tests create. Everything made through here is removed twice over:
/// early, by whoever owns it (`defer`, `deinit`, or `TempFiles.remove`), and at the latest when the test process exits,
/// so a failed test, a thrown error or a retained owner never leaves an `alloy-*` folder behind.
///
/// Only paths this type handed out are ever deleted; it never globs `$TMPDIR`.
public enum TempFiles {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var issued: Set<URL> = []
    nonisolated(unsafe) private static var hooked = false

    /// A fresh, not-yet-created path `$TMPDIR/<prefix>-<uuid><ext>`, removed at process exit if nobody removes it sooner.
    /// `resolveSymlinks` returns the `/private/var/...` form, which is what the file system reports back.
    public static func url(_ prefix: String, ext: String = "", resolveSymlinks: Bool = false) -> URL {
        var u = FileManager.default.temporaryDirectory.appendingPathComponent("\(prefix)-\(UUID().uuidString)\(ext)")
        if resolveSymlinks { u = u.resolvingSymlinksInPath() }
        track(u)
        return u
    }

    /// A log path for the fake language server (`FAKE_LSP_LOG`). The server writes `.docs`, `.errors` and `.launches` files next to
    /// it, so those are tracked too.
    public static func serverLog(_ prefix: String) -> URL {
        let u = url(prefix, ext: ".jsonl")
        for suffix in [".docs", ".errors", ".launches"] { track(URL(fileURLWithPath: u.path + suffix)) }
        return u
    }

    /// Like `url`, but the directory exists afterwards.
    public static func directory(_ prefix: String, resolveSymlinks: Bool = false) -> URL {
        let u = url(prefix, resolveSymlinks: resolveSymlinks)
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }

    /// Registers a path the test made itself (for example from a helper that takes the location as an argument).
    public static func track(_ url: URL) {
        lock.lock(); defer { lock.unlock() }
        issued.insert(url)
        if !hooked {
            hooked = true
            atexit { TempFiles.removeAll() }
        }
    }

    /// Removes one tracked path now.
    public static func remove(_ url: URL) {
        lock.lock(); issued.remove(url); lock.unlock()
        try? FileManager.default.removeItem(at: url)
    }

    static func removeAll() {
        lock.lock(); let all = issued; issued = []; lock.unlock()
        for u in all { try? FileManager.default.removeItem(at: u) }
    }
}

/// A scratch directory that deletes itself when its owner goes away. Hold it in a `let` of a test or fixture type.
public final class TempDir: @unchecked Sendable {
    public let url: URL
    public init(_ prefix: String = "alloy-scratch", resolveSymlinks: Bool = false) {
        url = TempFiles.directory(prefix, resolveSymlinks: resolveSymlinks)
    }
    public func file(_ rel: String) -> URL { url.appendingPathComponent(rel) }
    deinit { TempFiles.remove(url) }
}
