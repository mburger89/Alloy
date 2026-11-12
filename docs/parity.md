# Parity shortfalls

This file records metrics where a published parity run (`Bench/published/*.json`) shows Alloy behind Zed, and the
triage of each: what causes the gap, who owns it, and what to do next. Entries are triage only; none of them is a fix.

## Status - run 2026-11-11-222649

No open shortfalls: Alloy is ahead of Zed on 6 of 7 metrics and at par on scroll frame time. The large-file memory gap
below is resolved (Alloy 56.0 MiB vs Zed 186.2 MiB, median), by windowed highlighting for documents over 1 MiB
(`HighlightEngine`, merge fd473a6). The corpus is now Rust (`Bench/Corpus/*.rs`), which both editors highlight; the
run below used Swift, which Zed showed as plain text.

Found while re-running, not in any published run: idle CPU of 35.7% when the last row the code view asked colours for
was blank. `CodeViewHighlighter` answered up to the end of the row's text, so the blank row's newline byte stayed
unknown and MetalUI asked again every frame. Fixed in Alloy (merge 0496c49: rows are covered through their newline);
MetalUI gap G32 makes an empty answer unable to loop.

## memory (large file open) - run 2026-11-11-163850 (resolved)

| | median | p95 |
|---|---|---|
| Zed 1.28.1 | 102.2 MiB | 103.7 MiB |
| Alloy | 181.5 MiB | 181.8 MiB |

Verdict: **behind: median 181.5 MiB vs Zed 102.2 MiB** (pass bar: within max(5%, 2.0 MiB) of Zed).

Metric: `phys_footprint` of the whole process tree 10 s after text is painted with `corpus.large` open
(`MemoryScenario`). `corpus.large` is `Bench/Corpus/large.swift`: 100,000 lines, 2,232,639 bytes (2.1 MiB), Swift.
For context, `memoryIdle` (small.swift open) is Alloy 48.7 MiB vs Zed 93.4 MiB, so opening the large file costs Alloy
about 133 MiB and Zed about 9 MiB.

Attribution method: the frame-timing `--attribute` run does not apply to a memory metric. Attribution came from
headless measurement: `Tests/AlloyKitTests/MemoryProbeTests.swift` reads `task_info(TASK_VM_INFO).phys_footprint`
between stages. The probes are skipped unless `ALLOY_MEMPROBE=1`; run one per process for clean numbers:

    ALLOY_MEMPROBE=1 swift test --filter MemoryProbeTests/fullOpen
    ALLOY_MEMPROBE=1 ALLOY_MEMPROBE_NAME=large.txt swift test --filter MemoryProbeTests/fullOpen
    ALLOY_MEMPROBE=1 swift test --filter MemoryProbeTests/highlightEngineOpen
    ALLOY_MEMPROBE=1 swift test --filter MemoryProbeTests/documentModel

### Breakdown (Apple silicon, test process, deltas)

Full app path (`Workspace.open` + root view in a headless `TestWindow`, run until the code view exists and has settled):

| Stage | large.swift | large.txt (no grammar) |
|---|---|---|
| window + workspace, no file | 9.3 MiB | 9.4 MiB |
| code view exists, file loaded | 10.1 MiB | 9.0 MiB |
| first seconds of ticking (parse + first highlight) | **132.4 MiB** | 0.0 MiB |
| settle 3 s | 0.0 MiB | 0.0 MiB |
| total | 151.7 MiB | 18.4 MiB |

The 133 MiB gap in the published run is the tree-sitter parse of the whole file; without a grammar the open costs
about 9 MiB, the same as Zed's delta.

Document model alone (`documentModel`): `readForEditing` bytes 4.7 MiB, `CodeBuffer(utf8:)` rope 3.2 MiB,
`EditorDocument` (saved snapshot shares the rope) 0.03 MiB, line lookup 0.02 MiB.

Highlight engine alone (`highlightEngineOpen`): `snapshot.text` String 4.4 MiB (transient), **`engine.open` (full
parse) +132.9 MiB**, a whole-file `captures` call +127.9 MiB (a probe only; the app asks for the viewport), a
4000-byte capture +0.05 MiB, `engine.close` -234.6 MiB.

The ledger is not involved: `ledger.files` has no entry for a file that was only opened, so no `EditHistory`
fragments or `diffEntries` exist for it.

### Contributors

| # | Contributor | MiB | Cause | Owner | Evidence | Next action |
|---|---|---|---|---|---|---|
| 1 | Whole-file tree-sitter tree | ~133 | `HighlightEngine.open` parses all 2.1 MiB of source into a `MutableTree` kept for the document's life, about 1.4 KB per line (~62 bytes per source byte). Only the viewport is ever queried (4000 bytes cost 0.05 MiB). | Alloy (`Sources/AlloyHighlight/HighlightEngine.swift`) | `fullOpen` 132.4 MiB vs `large.txt` 0.0; `highlightEngineOpen` 132.9 MiB | Do not hold a whole-file tree for big files (see fixes below). |
| 2 | Window, Metal and code view | ~9-10 | Empty-window cost (9.3 MiB) plus view and file load (9.0 MiB); same with or without a grammar. | MetalUI / Alloy | `fullOpen` both columns | None needed; Zed's own delta is about 9 MiB. |
| 3 | Byte copies of the text | ~12 | `readForEditing` holds `Data` and a `[UInt8]` copy (4.7 MiB), the rope is 3.2 MiB (1.4x the text), the engine keeps `bytes` (2.2 MiB) and was fed a `snapshot.text` String (2.2 MiB, transient). | Alloy | `documentModel`, `highlightEngineOpen` | Read straight into the final array; feed the engine `snapshot.utf8(in:)` and skip the String hop. Minor (a few MiB). |
| 4 | Whole-file `captures` | 0 in the app | Probe only: a full-range query costs another 128 MiB transient, so any future feature that queries the whole file (outline, find in highlights) would double the peak. | Alloy | `highlightEngineOpen` | Keep queries range-limited. |

Caveat on the comparison: Zed ships Swift grammar support as an extension, not built in, so the Zed run may have
shown `large.swift` without syntax highlighting. The harness only waits for text to paint, so it cannot tell. If that
holds, the 133 MiB is "Alloy highlights the file, Zed did not" and the metric as written compares unlike work. Worth
checking with a screenshot of the Zed run or by switching the corpus to a language Zed bundles (Rust, JS, Python).

### Recommended fixes, ranked by MiB saved

1. **Stop holding a full tree for large files (~120-133 MiB).** Options, cheapest first:
   - Above a size or line threshold (for example 1 MiB or 20k lines), highlight a window only: parse the viewport
     plus margin as its own small document (or with `Parser.included_ranges`) and re-parse as the user scrolls.
     Footprint then follows the window, not the file.
   - Or skip tree-sitter above a larger threshold and show plain text, as Zed's own large-file mode does.
   - Or drop the tree after the viewport's runs are cached and rebuild on scroll or edit (costs CPU on scroll).
2. **Shrink the text copies (~5-8 MiB).** Single read into the buffer's final storage, no `String` hop into the
   engine, and have the engine borrow rope chunks instead of its own `[UInt8]`.
3. **Harness: confirm Zed highlights the corpus (0 MiB, validity).** If it does not, either pick a corpus language
   Zed supports out of the box or compare against Alloy with highlighting off.

No MetalUI change is needed for this metric.
