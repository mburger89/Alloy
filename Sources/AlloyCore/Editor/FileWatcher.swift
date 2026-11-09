import CoreServices
import Foundation

/// A stream of file changes under a project: each element is a batch of absolute paths.
public protocol FileChangeSource: Sendable {
    func changes() -> AsyncStream<[String]>
}

/// FSEvents with file-level events. Paths under `.build/`, `node_modules/` and `.swiftpm/` are dropped; `.git/`
/// paths are forwarded, because the workspace hands them to its `gitChanged` hook.
public struct FSEventsSource: FileChangeSource {
    public let root: URL
    public let latency: TimeInterval

    public init(root: URL, latency: TimeInterval = 0.1) {
        self.root = root; self.latency = latency
    }

    /// Whether `path` lies under a directory this source never reports. Only the part below `root` counts, so a
    /// project that itself lives under `node_modules/` still reports.
    public static func isIgnored(_ path: String, root: String) -> Bool {
        let below = path.hasPrefix(root + "/") ? String(path.dropFirst(root.count + 1)) : path
        return below.split(separator: "/", omittingEmptySubsequences: true)
            .contains { $0 == ".build" || $0 == "node_modules" || $0 == ".swiftpm" }
    }

    /// The path with every symlink resolved (`/var` becomes `/private/var`), which is how FSEvents reports it.
    public static func realPath(_ url: URL) -> String {
        guard let p = realpath(url.path, nil) else { return url.path }
        defer { free(p) }
        return String(cString: p)
    }

    public func changes() -> AsyncStream<[String]> {
        let root = Self.realPath(self.root), latency = self.latency
        return AsyncStream { continuation in
            let handler = Handler(continuation, root: root)
            var context = FSEventStreamContext(version: 0, info: Unmanaged.passRetained(handler).toOpaque(),
                                               retain: nil, release: nil, copyDescription: nil)
            let callback: FSEventStreamCallback = { _, info, count, rawPaths, flags, _ in
                guard let info else { return }
                let handler = Unmanaged<Handler>.fromOpaque(info).takeUnretainedValue()
                let paths = unsafeBitCast(rawPaths, to: CFArray.self) as? [String] ?? []
                var out: [String] = []
                for i in 0..<min(count, paths.count) {
                    let f = flags[i]
                    func set(_ flag: Int) -> Bool { f & FSEventStreamEventFlags(flag) != 0 }
                    // Events were dropped or coalesced: the whole project may have changed. A path with a trailing
                    // slash is a directory; the workspace looks at every file it knows below it.
                    if set(kFSEventStreamEventFlagMustScanSubDirs) || set(kFSEventStreamEventFlagUserDropped)
                        || set(kFSEventStreamEventFlagKernelDropped) {
                        out.append(handler.root + "/")
                    } else if set(kFSEventStreamEventFlagItemIsFile) || set(kFSEventStreamEventFlagItemIsSymlink) {
                        if !FSEventsSource.isIgnored(paths[i], root: handler.root) { out.append(paths[i]) }
                    } else if set(kFSEventStreamEventFlagItemIsDir),
                              set(kFSEventStreamEventFlagItemRemoved) || set(kFSEventStreamEventFlagItemRenamed),
                              !FSEventsSource.isIgnored(paths[i], root: handler.root) {
                        out.append(paths[i].hasSuffix("/") ? paths[i] : paths[i] + "/")
                    }
                }
                if !out.isEmpty { handler.continuation.yield(out) }
            }
            let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes
                                                 | kFSEventStreamCreateFlagNoDefer)
            guard let stream = FSEventStreamCreate(nil, callback, &context, [root] as CFArray,
                                                   FSEventStreamEventId(kFSEventStreamEventIdSinceNow), latency, flags) else {
                Unmanaged.passUnretained(handler).release()
                continuation.finish()
                return
            }
            FSEventStreamSetDispatchQueue(stream, handler.queue)
            FSEventStreamStart(stream)
            handler.stream = stream
            continuation.onTermination = { _ in
                handler.queue.async {
                    if let stream = handler.stream {
                        FSEventStreamStop(stream); FSEventStreamInvalidate(stream); FSEventStreamRelease(stream)
                        handler.stream = nil
                    }
                    Unmanaged.passUnretained(handler).release()
                }
            }
        }
    }

    private final class Handler: @unchecked Sendable {
        let continuation: AsyncStream<[String]>.Continuation
        let queue = DispatchQueue(label: "alloy.fsevents")
        let root: String
        var stream: FSEventStreamRef?
        init(_ c: AsyncStream<[String]>.Continuation, root: String) { continuation = c; self.root = root }
    }
}
