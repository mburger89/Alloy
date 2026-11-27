# Reply Row Split Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Render each assistant reply as one lazy transcript row per top-level Markdown block.

**Architecture:**
- `TranscriptView` flattens `[ChatBlock]` into `[TranscriptRow]` through a pure function. The function uses the shared
  `MarkdownCache`.
- `.assistantText` expands into one equatable piece row per `MarkdownBlock`. Every other block stays one
  `ChatBlockView` row.

**Tech Stack:** Swift 6, MetalUI (`LazyVStack`, `MetalUIMarkdown`), Swift Testing, the TestWindow rig.

**Spec:** docs/superpowers/specs/2026-11-26-reply-row-split-design.md

## Global Constraints

- No visible change. The gap between blocks stays 10 px (`LazyVStack` spacing equals `alloyMarkdownTheme.blockSpacing`).
  Copy-button identifiers stay `copy-code-<blockID>-<block.id>-<n>`.
- Piece 0's row id and identifier are the reply's block id (`block-<id>`). Piece n > 0 is `<id>-md<markdownBlockID>`,
  identified `block-<id>-md<markdownBlockID>`.
- An empty reply still has a piece-0 row.
- No MetalUI edits. If MetalUI is missing something, stop and report it.
- Run tests with `swift test --no-parallel --filter …`. `swiftlint --strict` must be clean.
- Never weaken an assertion, raise a timeout or raise a frame guard. Test helpers may read a reply across its pieces
  (see the spec).
- Append the measurements to `Bench/results/perf-history.jsonl` in the existing JSON-lines shape. Delete raw logs.

## Review Focus

1. **"Show in chat" on a reply far up a long session** still scrolls to it. Task 2:
   `showInChatReachesASplitReply`.
2. **Streaming at the bottom** keeps the last line in view and doesn't jump when a delta starts a new block. Task 2:
   `streamingNewBlocksKeepsTheBottomPinned`.
3. **A non-append rewrite** of a reply (the text is replaced, or a block is merged away) leaves no stale piece rows.
   Task 2: `rewrittenReplyDropsStalePieces`.
4. **Thinking-row default collapse** ("collapses once text follows") still keys off `ChatBlock`s, not rows. The existing
   `aThinkingRowCollapsesWhenTextFollowsIt` must still pass.
5. **Code-block Copy and expand state** (`CodeBlockState`, keyed by block id) still work in piece rows. The existing
   copy-code tests, plus `copyButtonIdentifiersUnchanged`.

---

### Task 1: Long-reply benchmark, measured on the current code

**Files:**
- Modify: `Tests/AlloyKitTests/TranscriptRowRerunTests.swift`.

- [ ] **Step 1: Add `measureLongReply`.**
  - A transcript with the existing 22 mixed blocks, then one assistant reply of about 25 KB (about 150 top-level blocks:
    paragraphs, three fences, a list and a table), streamed in 30 deltas at the bottom.
  - After streaming, scroll from the bottom to the top in 20 equal steps.
  - Print `LONG per-delta requests=… prepaints=… markdownTopBlock=…` and
    `LONG per-scroll-step requests=… prepaints=…`, using the same counters as `measureStreamingRows`.
  - Add `BodyProbe.hit("MarkdownTopBlock")` to `MarkdownTopBlock.content` so it can be counted.
- [ ] **Step 2:** Run `measureStreamingRows` and `measureLongReply` 3 times each on this commit (`--no-parallel`). Record
  the numbers as the baseline in perf-history, with scenario `transcript-long-reply`.
- [ ] **Step 3:** Commit: `test(transcript): long-reply streaming and scroll benchmark`.

### Task 2: One lazy row per Markdown block

**Files:**
- Create: `Sources/AlloyKit/TranscriptRows.swift`.
- Modify:
  - `Sources/AlloyKit/ChatView.swift` (`TranscriptView`, the `ForEach` at about :99).
  - `Sources/AlloyKit/ChatBlockViews.swift` (`AssistantText`).
  - `Sources/AlloyKit/MarkdownText.swift` (`MarkdownTopBlock` is reused by the piece).
  - The test helpers that read reply text (`visibleText` in TranscriptRowRerunTests, and any others found by
    `grep -rn 'block-\\\\(' Tests`).
- Test: `Tests/AlloyKitTests/TranscriptRowSplitTests.swift`.

**Interfaces:**
- `enum TranscriptRow: Identifiable`:
  - `case block(ChatBlock)`
  - `case replyPiece(blockID: String, block: MarkdownBlock?)`. The block is nil only for an empty reply.
  - `id`: the block's id, the reply's id for piece 0, or `"<blockID>-md<id>"` for later pieces.
- `@MainActor static func rows(_ blocks: [ChatBlock], cache: MarkdownCache) -> [TranscriptRow]`.
- The piece component is equatable on `(blockID, block)` and identified per the Global Constraints.
  - It wraps `MarkdownTopBlock` in the same `.frame(maxWidth: .infinity, alignment: .leading)` and accessibility
    container as `ChatBlockView` gives a row.
  - Keep `BodyProbe.hit("AssistantText")` in it, so the existing rerun tests still count reply work.
- `TranscriptView` computes `defaults`, `scrollDecision` and `codeBlocks.prune` from `blocks`, exactly as today. Only the
  `ForEach` runs over `rows`.

- [ ] **Step 1: Write the failing tests** in `TranscriptRowSplitTests`.
  - `replySplitsIntoOneRowPerTopLevelBlock`: a reply with 3 paragraphs and a fence has elements `block-<id>`,
    `block-<id>-md1`, `block-<id>-md2` and `block-<id>-md3`, in vertical order.
  - `emptyReplyStillHasItsRow`: `block-<id>` exists while the reply's text is "".
  - `offscreenPiecesHaveNoElements`: in a 200-paragraph reply scrolled to the bottom, `block-<id>-md5` is absent.
  - `spacingBetweenPiecesIsTen`: the gap from the bottom of piece 0 to the top of piece 1 is 10 px.
  - `copyButtonIdentifiersUnchanged`: the fence's button is `copy-code-<id>-<fenceBlockID>-0`.
  - `onlyTheLastPieceRerunsPerDelta`: over 30 appending deltas of a 20-block reply, the `MarkdownTopBlock` bodies are at
    most deltas + (new blocks created).
  - `rewrittenReplyDropsStalePieces`: a reply goes from 5 blocks to 2 by a non-append change, and `block-<id>-md3` is
    gone.
  - `showInChatReachesASplitReply`: in a 60-block session, `scrollTarget` = an early reply's id brings `block-<id>`
    into view.
  - `streamingNewBlocksKeepsTheBottomPinned`: while deltas start new paragraphs at the bottom, the last piece's maxY
    stays within the viewport after each delta.
- [ ] **Step 2:** Run `--filter TranscriptRowSplitTests`. Expect FAIL.
- [ ] **Step 3: Implement** `TranscriptRows.swift`, the piece component and the `TranscriptView` `ForEach` switch.
  `AssistantText` then has no transcript use. Delete it if nothing else uses it, and update its probe-name references in
  the tests.
- [ ] **Step 4:** Run `TranscriptRowSplitTests`, `TranscriptRowRerunTests`, `ChatTests`, `SessionMessageViewTests`, the
  copy-code and markdown suites, and CodeModePerformanceTests with the frame-guard suites. Expect PASS.
- [ ] **Step 5: Measure.** Run `measureStreamingRows` and `measureLongReply` 3 times each. Append scenario
  `transcript-long-reply` to perf-history with the after numbers and the commit.
  - Expect the long-reply per-scroll-step requests and prepaints to drop clearly.
  - Expect per-delta requests to be no worse than the baseline.
  - If they are worse, stop and report.
- [ ] **Step 6:** Run `swiftlint --strict`, then commit: `perf(transcript): one lazy row per Markdown block of a reply`.
