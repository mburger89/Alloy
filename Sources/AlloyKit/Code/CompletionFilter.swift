import AlloyCore
import AlloyLSP
import Foundation

/// Which completion items the popup shows for what is typed, best first.
enum CompletionFilter {
    /// The most items a list is cut to before filtering (a longer decoded list never exists; see `CompletionParsing.itemCap`).
    static let itemCap = CompletionParsing.itemCap

    /// Indices into `items`, at most `limit`: items whose `filterText ?? label` the query is a fuzzy subsequence of, by score
    /// (higher first), then `sortText ?? label`, then label. An empty query keeps every item in `sortText` order. Meant to run
    /// off the main actor; it returns what it has when its task is cancelled.
    static func top(_ items: [CompletionItem], query: String, limit: Int = 50) -> [Int] {
        var scored: [(score: Int, index: Int)] = []
        scored.reserveCapacity(min(items.count, itemCap))
        for index in items.indices.prefix(itemCap) {
            if index & 1023 == 0, Task.isCancelled { return [] }
            let item = items[index]
            if query.isEmpty { scored.append((0, index)); continue }
            if let score = FuzzyMatch.score(query, item.filterText ?? item.label) { scored.append((score, index)) }
        }
        scored.sort { a, b in
            if a.score != b.score { return a.score > b.score }
            let x = items[a.index], y = items[b.index]
            let sx = x.sortText ?? x.label, sy = y.sortText ?? y.label
            if sx != sy { return sx < sy }
            if x.label != y.label { return x.label < y.label }
            return a.index < b.index
        }
        return scored.prefix(limit).map(\.index)
    }
}
