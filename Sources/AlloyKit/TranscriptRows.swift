import AlloyCore
import Foundation
import MetalUI
import MetalUIMarkdown

/// One row of the transcript's lazy stack. Every block is one row, except an assistant reply: it becomes one row per
/// top-level Markdown block, so the lazy stack builds and paints only the pieces on screen.
enum TranscriptRow: Identifiable {
    case block(ChatBlock)
    /// A piece of the reply `blockID`. The block is nil only for an empty reply, which keeps its piece-0 row.
    case replyPiece(blockID: String, block: MarkdownBlock?)

    /// The block's id; the reply's id for piece 0; `<blockID>-md<id>` for later pieces.
    var id: String {
        switch self {
        case .block(let block): block.id
        case .replyPiece(let blockID, let block):
            if let block, block.id != 0 { "\(blockID)-md\(block.id)" } else { blockID }
        }
    }

    /// The transcript's rows. A reply's document comes from the shared `cache`, which appends while a reply streams.
    @MainActor
    static func rows(_ blocks: [ChatBlock], cache: MarkdownCache) -> [TranscriptRow] {
        var out: [TranscriptRow] = []
        out.reserveCapacity(blocks.count)
        for block in blocks {
            guard case .assistantText(let id, let text) = block else { out.append(.block(block)); continue }
            let pieces = cache.document(for: id, text: text).blocks
            if pieces.isEmpty { out.append(.replyPiece(blockID: id, block: nil)) }
            for piece in pieces { out.append(.replyPiece(blockID: id, block: piece)) }
        }
        return out
    }
}

/// One top-level Markdown block of a reply, as a transcript row. Piece 0 is identified `block-<reply id>`, the others
/// `block-<reply id>-md<block id>`. Equatable on the stored values, so a streaming token re-runs only the last piece.
struct ReplyPiece: Component, @MainActor Equatable {
    let blockID: String
    let block: MarkdownBlock?

    static func == (l: ReplyPiece, r: ReplyPiece) -> Bool { l.blockID == r.blockID && l.block == r.block }

    var content: some ElementGroup {
        let _ = BodyProbe.hit("AssistantText")
        let identifier = TranscriptRow.replyPiece(blockID: blockID, block: block).id
        VStack(alignment: .leading, spacing: 0) {
            if let block { MarkdownTopBlock(blockID: blockID, block: block).equatable() }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("block-\(identifier)")
    }
}
