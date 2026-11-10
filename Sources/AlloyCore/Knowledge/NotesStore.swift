import Foundation

/// What a note is about: a project file (project-relative path) or a free-form topic.
public enum NoteSubject: Codable, Sendable, Equatable, Hashable {
    case file(String)
    case topic(String)
}

/// A summary one session left for the others. A file note is tied to the file's stamp when it was written.
public struct Note: Codable, Sendable, Equatable {
    public var id: UUID
    public var author: UUID
    public var subject: NoteSubject
    public var text: String
    /// Required for `.file` notes; nil for topics.
    public var stamp: FileStamp?
    public var date: Date
    /// When the note was first seen to be out of date; `NotesStore.expire` drops it `staleExpiry` later.
    public var staleSince: Date?
    /// The writing session's display name; nil for notes written before the pool existed.
    public var authorName: String?
    /// The writer's real project root; nil for notes written before the pool existed.
    public var project: String?

    public init(id: UUID = UUID(), author: UUID, subject: NoteSubject, text: String, stamp: FileStamp?, date: Date,
                staleSince: Date? = nil, authorName: String? = nil, project: String? = nil) {
        self.id = id; self.author = author; self.subject = subject; self.text = text
        self.stamp = stamp; self.date = date; self.staleSince = staleSince
        self.authorName = authorName; self.project = project
    }
}

/// Session-written notes, persisted as `notes.json` beside the read index.
public struct NotesStore: Codable, Sendable, Equatable {
    /// Longest note text, in characters.
    public static let noteLimit = 2_000
    /// How long a stale note is kept.
    public static let staleExpiry: TimeInterval = 7 * 24 * 60 * 60
    /// Most notes kept per subject; adding more drops the oldest.
    public static let perSubjectLimit = 20
    /// Most topics kept (file notes are bounded by the project's files and go stale on their own); adding a note on a
    /// new topic past this drops the topic that was written to longest ago.
    public static let topicLimit = 200

    public private(set) var all: [Note] = []

    public init() {}

    /// A store holding exactly `notes`, as loaded (no limits applied).
    init(notes: [Note]) { all = notes }

    /// A topic is matched by its trimmed name without regard to case ("Auth" finds "auth").
    static func topicKey(_ name: String) -> String { name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }

    static func same(_ a: NoteSubject, _ b: NoteSubject) -> Bool {
        if case .topic(let x) = a, case .topic(let y) = b { return topicKey(x) == topicKey(y) }
        return a == b
    }

    /// Notes for `subject`, oldest first.
    public func notes(for subject: NoteSubject) -> [Note] { all.filter { Self.same($0.subject, subject) } }

    /// Whether `note` still describes the file as it is now (`stamp` nil: the file is gone). Topics never go stale.
    public func isCurrent(_ note: Note, stamp: FileStamp?) -> Bool {
        guard case .file = note.subject else { return true }
        guard let stamp, let held = note.stamp else { return false }
        return held == stamp
    }

    public mutating func add(_ note: Note) {
        all.append(note)
        let same = all.indices.filter { Self.same(all[$0].subject, note.subject) }
        if same.count > Self.perSubjectLimit {
            let drop = Set(same.prefix(same.count - Self.perSubjectLimit))
            all = all.enumerated().filter { !drop.contains($0.offset) }.map(\.element)
        }
        if case .topic = note.subject { evictTopics() }
    }

    private mutating func evictTopics() {
        var newest: [String: Date] = [:]
        for n in all { if case .topic(let t) = n.subject { newest[Self.topicKey(t), default: .distantPast] = max(newest[Self.topicKey(t)] ?? .distantPast, n.date) } }
        while newest.count > Self.topicLimit, let oldest = newest.min(by: { ($0.value, $0.key) < ($1.value, $1.key) })?.key {
            newest.removeValue(forKey: oldest)
            all.removeAll { if case .topic(let t) = $0.subject { Self.topicKey(t) == oldest } else { false } }
        }
    }

    /// Records, for the file's notes, whether they are stale now: the first sighting starts the expiry clock, and a
    /// file that returns to the noted stamp clears it. Returns whether anything changed.
    @discardableResult
    public mutating func reconcile(path: String, stamp: FileStamp?, at date: Date) -> Bool {
        var changed = false
        for i in all.indices where all[i].subject == .file(path) {
            let stale: Date? = isCurrent(all[i], stamp: stamp) ? nil : (all[i].staleSince ?? date)
            if all[i].staleSince != stale { all[i].staleSince = stale; changed = true }
        }
        return changed
    }

    /// Drops notes that have been stale since before `date`.
    @discardableResult
    public mutating func expire(before date: Date) -> Bool {
        let n = all.count
        all.removeAll { ($0.staleSince ?? .distantFuture) < date }
        return all.count != n
    }

    var paths: Set<String> {
        Set(all.compactMap { if case .file(let p) = $0.subject { return p } else { return nil } })
    }
}
