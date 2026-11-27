# Assistant reply row split: design

## Why

Today an assistant reply is one row of the transcript's `LazyVStack`. `AssistantText` → `MarkdownText` puts every
top-level Markdown block in a plain `VStack`. MetalUI reports that a whole reply in one row places and paints every
glyph of the reply each frame. That cost grows with the reply's length while it streams and while the user scrolls.
The goal is to split the reply so the lazy stack only builds and paints the blocks on screen.

This serves the standing rule: "It is important that alloy is fast but it also should not use a ton of memory or
resources to simply run".

## Goals

- An `.assistantText` block becomes one lazy row per top-level `MarkdownBlock`. Off-screen blocks of a long reply have
  no elements.
- While a reply streams, only the last block's row re-renders. Settled blocks stay `.equatable()` hits.
- Nothing visible changes. The gap between blocks stays 10 px, because `LazyVStack` spacing equals
  `MarkdownTheme.blockSpacing` at 10. Code Copy buttons keep their identifiers. Fence colours, tables and quotes look
  the same.
- Measured before and after, and logged in `Bench/results/perf-history.jsonl`.

## Non-goals

- `NoticeRow` (command output) and `PlanCard` keep the single `MarkdownText`. Their text sits inside a chrome card and
  is short.
- No change to MetalUI. If something is missing, forward it to MetalUI.
- No change to parsing. `MarkdownCache` stays as it is.

## Anti-goals (a failure even if it works)

- Any shift in reply layout, or a jump in scroll position while streaming at the bottom.
- "Show in chat" (`scrollTarget` → `proxy.scrollTo(blockID)`) stops reaching a reply.
- An empty reply that has just started streaming has no row, so it has no `block-<id>` and nothing to scroll to.
- More work per delta than today (`TranscriptRowRerunTests` numbers get worse).

## Approaches

1. **Flatten in `TranscriptView`. Chosen.** A pure function turns `[ChatBlock]` into `[TranscriptRow]`, using the
   shared `MarkdownCache` for the reply's document. `ForEach` runs over rows. Each reply piece is an equatable row
   holding `(blockID, MarkdownBlock)`. The trade-off is that the parse moves from the row body into the transcript
   body, which already re-runs on every delta. The cost is the same, because the cache appends.
2. **A nested lazy stack inside the reply row.** Rejected: MetalUI's lazy stack virtualises against its own scroll
   view, so a nested one inside a row would build every child anyway.
3. **Ask MetalUI to make `MarkdownView` paint incrementally.** Rejected as the first move: the row split is Alloy's
   share, and MetalUI asked for it.

## Decisions

- **Row ids.** Piece 0 of a reply uses the reply's block id, so `scrollTo(blockID)` and `block-<id>` keep working.
  Piece n > 0 uses `"<blockID>-md<markdownBlock.id>"`, and its identifier is `block-<blockID>-md<id>`.
- **Empty reply.** It gets one empty piece-0 row, so the row exists from the first delta.
- **Accessibility.** Each piece is its own `.accessibilityElement(children: .contain)`, which is the lazy-row
  trade-off. The reply's text reads in order.
- **Tests.** Helpers that read a reply's whole text through `block-<id>` collect piece 0 plus every
  `block-<id>-md*` piece, in order. That keeps their meaning without weakening any assertion.

## Left to the builder

The names of the row enum and the piece component, and where the flatten function lives (a new focused file is
preferred).
