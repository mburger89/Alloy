# MetalUI API surface for Alloy plans 3-4 (research, read-only)

Repo `../MetalUI` (github.com/mburger89/MetalUI). Paths below are relative to it; `file:line` is the **local checkout** unless marked `origin/master`.

## 0. Checkout state
- Local HEAD: `b0fa5ae5 Merge pull request #226 from mburger89/feat/code-find` (branch `master`; log -3: b0fa5ae5, ecd7cc9d "Tasks: G1 PR 4 is PR #226", fa57bee5 "CodeView find: counts, verification lines of record 229").
- **Local HEAD does NOT include the symbol-images merge 60c733de** (`git merge-base --is-ancestor` fails). It IS in `origin/master` (2da93ec6, PR #229 lucide-icons), which is 19 commits ahead of local. Local master has not been pulled. `Sources/MetalUI/Code/` and `Sources/MetalUICodeBuffer/` are byte-identical between HEAD and origin/master (diff touches only symbol/icon files), so section 1-2 line numbers hold on both. Section 3 line numbers are `origin/master`.
- Block markdown (G2) exists only on `origin/feat/markdown-parser` (parser target, no view). `origin/feat/drag-and-drop` is an old (Oct 1) branch, not relevant (drag and drop is already on master).
- Tasks.md (lines 195-201): G1 CodeView (PRs 1-4 done), G2 block markdown (open), G3 symbols (open on local, merged PRs 1-2 on origin), G4 closable tab bar (open, nothing built), G5 two-axis ScrollView (open, nothing built), G6 defaultScrollAnchor (done), G7 frame timing (done).

## 1. MetalUICodeBuffer (portable target, imports only Observation; `@_exported` by MetalUI)
Everything offsets = **UTF-8 byte offsets**. `CodeBuffer` is `@MainActor @Observable`; read from other threads via `snapshot()` (Sendable).

### Value types (`Sources/MetalUICodeBuffer/CodeTypes.swift`)
```swift
:3   public struct CodePoint: Hashable, Comparable, Sendable { public var row: Int; public var column: Int /* UTF-8 bytes in row */; public init(row: Int, column: Int) }
:22  public struct CodeTransactionID: Hashable, Sendable { public let rawValue: UInt64; public init(rawValue: UInt64) }
:32  public struct CodeSelection: Hashable, Sendable {
:34    public var anchor: Int ; :36 public var head: Int   // head is the moving end; head<anchor = backwards
:39    public init(anchor: Int, head: Int) ; :45 public init(caret offset: Int)
:51    public var range: Range<Int> { min..<max } ; :54 public var isEmpty: Bool }
:58  public struct CodeTextEdit: Sendable { public var range: Range<Int>; public var text: String; public init(range: Range<Int>, text: String) }  // coords of text BEFORE any edit of the group
:72  public enum CodeEditOrigin: Hashable, Sendable { case typing, paste, deletion, undo(CodeTransactionID), redo(CodeTransactionID), external, programmatic }
     // typing/deletion coalesce into one undo step; .external = file reload/agent patch, not undoable
:90  public struct CodeEdit: Sendable {   // one replacement, coordinates of the text just BEFORE it
       public let version: UInt64            // buffer version AFTER event; +1 per event, never reused
       public let transaction: CodeTransactionID; public let origin: CodeEditOrigin
       public let range: Range<Int>          // replaced bytes (before)
       public let scalarRange: Range<Int>    // replaced scalars (before)
       public let startPoint: CodePoint; public let oldEndPoint: CodePoint  // before ; public let newEndPoint: CodePoint // after
       public let newText: String
       public init(version:transaction:origin:range:scalarRange:startPoint:oldEndPoint:newEndPoint:newText:) }
:128 public enum CodeEditBatch: Sendable { case edits([CodeEdit]) /* oldest first, maybe empty */; case resync(CodeSnapshot) /* cursor fell behind the log cap */ }
:136 public enum CodeBufferError: Error, Sendable, Equatable { case stale(current: UInt64); case readOnly; case invalidRange }
:146 public enum CodeBias: Sendable { case before, after }          // offset at an insertion point: stay in front / move behind
:154 public enum CodeLineEnding: Sendable { case lf, crlf; public var text: String }
:165 public struct CodeFindOptions: OptionSet, Sendable { static let caseInsensitive (1) /* ASCII only */, wholeWord (2) /* ASCII alnum/_ or any non-ASCII scalar is a word char */ }
```

### CodeBuffer (`CodeBuffer.swift`)
```swift
:52  @MainActor @Observable public final class CodeBuffer {
:54    public private(set) var version: UInt64 = 0                 // observable; +1 per edit event
:56    public private(set) var revealSerial: UInt64 = 0            // rises on select(_:reveal:true); views observe it
:58    public var lineEnding: CodeLineEnding = .lf                 // detected at creation; Return inserts it
:60    public var isReadOnly = false                               // refuses edits; still selects/snapshots
:63    public let hadInvalidUTF8: Bool                             // init(utf8:) saw invalid bytes (became U+FFFD) -> app may refuse to save
:65    @ObservationIgnored public var undoByteLimit = 8 << 20
:90    public init(_ text: String = "")
:99    public init(utf8 bytes: some Collection<UInt8>)
:141   public var utf8Count: Int ;  :143 public var lineCount: Int   // lines = newlines + 1
:146   public func snapshot() -> CodeSnapshot                       // O(1), Sendable
:155   public var selections: [CodeSelection] { get set }          // sorted+merged; always >=1; assigning ends undo coalescing
:164   public var primarySelection: CodeSelection
:168   public func select(_ range: Range<Int>, reveal: Bool = true) // reveal = centre head's row in every view of the buffer
:174   public func breakUndoCoalescing()
:226   @discardableResult public func replace(_ range: Range<Int>, with text: String, origin: CodeEditOrigin = .programmatic) -> CodeTransactionID  // PRECONDITION: range in bounds + on scalar boundary (traps otherwise); no-op if read-only
:245   @discardableResult public func transaction(_ body: (CodeBuffer) -> Void) -> CodeTransactionID   // one undo step; nested joins outer
:265   @discardableResult public func replaceSelections(with text: String, origin: CodeEditOrigin = .typing) -> CodeTransactionID
:364   public var canUndo: Bool ; :366 public var canRedo: Bool
:372   public func undo() -> Bool ; :383 public func redo() -> Bool       // (not @discardableResult)
:413   @discardableResult public func applyExternalEdits(_ edits: [CodeTextEdit], expectingVersion: UInt64? = nil) throws(CodeBufferError) -> CodeTransactionID
          // origin .external, NOT an undo step, coords of current text, applied highest-range-first; selections/undo stacks are mapped (undo step touching an edited range is dropped with every older step). Atomic: throws .stale/.readOnly/.invalidRange and applies nothing.
:423   @discardableResult public func applyExternalReplacement(_ text: String, expectingVersion: UInt64? = nil) throws(CodeBufferError) -> CodeTransactionID?
          // prefix/suffix kept + line diff of middle, one event per hunk; O(n); nil when already equal. For reload / git checkout.
:507   public func makeEditCursor() -> CodeEditCursor
:549   public func map(_ offset: Int, from version: UInt64, bias: CodeBias) -> Int?
          // offset at `version` -> now. At insertion point goes by bias; inside replaced text collapses to start (.before) / end (.after). nil if log no longer reaches `version` (or future version).
```
### CodeEditCursor (`CodeEditCursor.swift:6`)
```swift
@MainActor public final class CodeEditCursor { public private(set) var version: UInt64; public func drain() -> CodeEditBatch }
```
Weakly held by buffer; log kept back to slowest live cursor up to a byte cap (cursor past the cap gets `.resync(snapshot)`). Wake on `buffer.version` (Observation), then `drain()`.

### CodeSnapshot (`CodeSnapshot.swift`, `public struct ... : Sendable`)
```swift
:9 public let version: UInt64
:17 utf8Count, :19 scalarCount, :21 utf16Count, :23 lineCount, :25 longestLineScalars   (Int vars)
:28 public var text: String ; :31 public func text(in range: Range<Int>) -> String ; :41 public func utf8(in range: Range<Int>) -> [UInt8]
:52 public func lineRange(_ row: Int) -> Range<Int> ; :62 public func line(_ row: Int) -> String
:66 public func offset(of point: CodePoint) -> Int ; :74 public func point(at offset: Int) -> CodePoint
:80 scalarOffset(ofUTF8:) ; :82 utf8Offset(ofScalar:) ; :84 utf16Offset(ofUTF8:) ; :86 utf8Offset(ofUTF16:) ; :89 byte(at:) -> UInt8 ; :92 isScalarBoundary(_:)
:99 public func ranges(of query: String, options: CodeFindOptions = [], limit: Int? = nil) -> [Range<Int>]   // sorted, disjoint; O(n)
```
(`ExternalDiff.swift` is internal.) Tests: `Tests/MetalUICodeBufferTests` (45 tests, portable).

## 2. CodeView + decorations (`Sources/MetalUI/Code/`)
`CodeView` is an `Element, StyledElement` **leaf** (not a `View`-protocol type; used directly as root/child of the element builder). One leaf: only visible rows shaped (open 100k lines = visible rows), sizes to its proposal, never reads the buffer when measured, scrolls itself (vertical+horizontal), gutter always on the left (ignores RTL), whole-device-pixel line pitch.
```swift
CodeView.swift:27  public struct CodeView: Element, StyledElement {
:34  public let buffer: CodeBuffer ; :36 public let decorations: CodeDecorations
:50  public init(buffer: CodeBuffer, decorations: CodeDecorations)   // precondition: decorations.buffer === buffer
:59  public func font(family: String? = nil, size: Double) -> CodeView          // nil family = system monospaced
:67  public func showsLineNumbers(_ shown: Bool) -> CodeView                    // default true
:74  public func tabWidth(_ columns: Int) -> CodeView                           // default 4 (multiples of space advance)
:83  public func codeViewEditable(_ editable: Bool) -> CodeView                  // DEFAULT TRUE (editable); false = still selects/copies/moves caret/scrolls; Tab moves focus
:91  public func indentUsingSpaces(_ spaces: Bool) -> CodeView                  // default false (Tab = tab char)
:100 public func scrollState(_ state: CodeScrollState) -> CodeView
:111 public func onScroll(_ action: @escaping @MainActor (CodeScrollPosition) -> Void) -> CodeView
:121 public func onGutterBarClick(_ action: @escaping @MainActor (CodeGutterHit) -> Void) -> CodeView
:130 public func gutterBarContextMenu<M: MenuContent>(@MenuContentBuilder _ content: @escaping @MainActor (CodeGutterHit) -> M) -> CodeView
:139 public func codeCaretBlink(_ blink: CodeCaretBlink) -> CodeView            // enum CodeCaretBlink { case on, off } (CodeView.swift:263); .off for tests/screenshots
```
No soft wrap, no tree-sitter, no minimap (soft wrap is "PR 6 of the plan", not built). Usual StyledElement modifiers (frame etc.) apply: `CodeView(buffer:decorations:).font(size: 12).frame(width: Pixels(600), height: Pixels(400))`.

### CodeDecorations (`CodeDecorations.swift`) -- `@MainActor @Observable public final class`
```swift
:166 public final class CodeDecorations {
:168  @ObservationIgnored public let buffer: CodeBuffer
:170  public var theme: CodeTheme
:172  @ObservationIgnored public weak var highlightProvider: (any CodeHighlightProvider)?   // NOT retained
:201  public init(buffer: CodeBuffer)
:224  public func register(_ style: CodeStyle) -> CodeStyleID       // equal styles share an id; max 65535
:235  public func style(_ id: CodeStyleID) -> CodeStyle
:303  public var findMatches: [Range<Int>] { get set }               // UTF-8 offsets into text NOW; sorted+thinned to disjoint on set; follows edits (touched match dropped; .resync clears)
:337  public var currentMatch: Int? { get set }                        // index in findMatches; follows/becomes nil
:440  public func setHighlights(_ runs: [CodeStyleRun], in range: Range<Int>, layer: CodeHighlightLayer = .syntax, asOf version: UInt64)
:461  public func invalidateHighlights(in range: Range<Int>, layer: CodeHighlightLayer = .syntax)
:476  public func setLineDecorations(_ decorations: [CodeLineDecoration], asOf version: UInt64)   // REPLACES all
:501  public func setVirtualRows(_ rows: [CodeVirtualRow], asOf version: UInt64)                  // REPLACES all
:520  public var virtualLineCount: Int
```
Semantics: `asOf` = buffer.version the offsets/rows were computed at; MetalUI maps them forward through later edits (highlights via `buffer.map`, rows via per-edit newline deltas, O(log n)). If the edit log no longer reaches back to `asOf` the call is **silently dropped** (highlights then re-requested via provider). `setHighlights` `range` gaps become "no style, valid"; run offsets are absolute buffer bytes. `setVirtualRows` group anchored inside rows an edit removes is dropped with them (app must re-give rows). `findMatches` has **no `asOf`**: assign on main actor, check `snapshot.version == buffer.version` after background search.
```swift
:5   public struct CodeStyleID: Hashable, Sendable { public let rawValue: UInt16; public init(rawValue: UInt16) }
:15  public struct CodeStyle: Hashable, Sendable { public var foreground: Color?; public var background: Color?; public init(foreground: Color? = nil, background: Color? = nil) }   // COLOUR ONLY: no weight/italic (would change glyph positions, CV-L)
:29  public struct CodeStyleRun: Sendable { public var range: Range<Int>; public var style: CodeStyleID; public init(range: Range<Int>, style: CodeStyleID) }
:43  public struct CodeLineDecoration: Sendable { public var lines: Range<Int> /*0-based buffer rows as of asOf*/; public var gutterBar: Color?; public var background: Color?; public var tag: UInt64?
:56     public init(lines: Range<Int>, gutterBar: Color? = nil, background: Color? = nil, tag: UInt64? = nil) }   // different tags never merge into one hit range
:66  public enum CodeHighlightLayer: Int, Comparable, CaseIterable, Sendable { case annotations, syntax, semantic, diagnostics }   // later layer's foreground wins; backgrounds painted in layer order; annotations sit under syntax
:81  public struct CodeTheme: Equatable, Sendable { public var foreground: Color; background: Color; selection: Color; caret: Color?; gutterForeground: Color; gutterBackground: Color?; findMatch: Color; currentFindMatch: Color; currentLine: Color?
:102    public init(foreground: Color = .textPrimary, background: Color = Color(.surface), selection: Color = Color.accentColor.opacity(0.3), gutterForeground: Color = Color.textPrimary.opacity(0.4), gutterBackground: Color? = nil, caret: Color? = nil, findMatch: Color = Color.yellow.opacity(0.35), currentFindMatch: Color = Color.orange.opacity(0.65), currentLine: Color? = nil) }
:129 @MainActor public protocol CodeHighlightProvider: AnyObject { func decorations(_ decorations: CodeDecorations, needHighlightsForRows rows: Range<Int>, in snapshot: CodeSnapshot) }
```
Provider contract (doc :123-127): called after a frame, outside every phase, at most once per frame, not again for the same rows until buffer/decorations change; answer now or later with `setHighlights(asOf: snapshot.version)`; until then rows draw old shifted runs (no flash of plain text). Only `.syntax` layer is requested from the provider; other layers are app-pushed.
```swift
CodeVirtualRow.swift:5  public struct CodeGutterMarker: Hashable, Sendable { public var text: String; public var color: Color?; public init(_ text: String, color: Color? = nil) }
:24 public struct CodeVirtualRow: Sendable {
:26   public enum Anchor: Hashable, Sendable { case before(line: Int) /* line == lineCount = after last */; case after(line: Int) }
:47   public var anchor: Anchor ; :49 lines: [String] ; :52 styleRuns: [[CodeStyleRun]] /*per line, offsets from line start, must not overlap*/ ; :54 gutterBar: Color? ; :56 background: Color? ; :58 gutterMarker: CodeGutterMarker? ; :61 tag: UInt64?
:64   public init(anchor: Anchor, lines: [String], styleRuns: [[CodeStyleRun]] = [], gutterBar: Color? = nil, background: Color? = nil, gutterMarker: CodeGutterMarker? = nil, tag: UInt64? = nil)
:77   public static func filler(_ count: Int, at anchor: Anchor, background: Color? = nil, gutterBar: Color? = nil) -> CodeVirtualRow }
   // Not buffer text: no line number, not selectable/copyable/editable, scroll with the buffer. A "line" is text up to first line break.
CodeGutterHit.swift:3  public struct CodeGutterHit: Equatable, Sendable {
:5   public enum Source: Equatable, Sendable { case lineDecoration, virtualRow }
:13  public var lines: Range<Int> /*buffer lines the bar spans; virtual row: anchor line as 1-line range*/ ; :15 tag: UInt64? ; :17 source: Source ; :19 displayRow: Int
:22  public init(lines: Range<Int>, tag: UInt64?, source: Source, displayRow: Int) }
CodeScroll.swift:9  public struct CodeScrollPosition: Equatable, Sendable { public var row: Double /*DISPLAY row + fraction (virtual rows count)*/; public var x: Double /*points*/; public init(row: Double = 0, x: Double = 0) }
:30 @MainActor @Observable public final class CodeScrollState { public init(_ position: CodeScrollPosition = CodeScrollPosition()); public var position: CodeScrollPosition { get set } }
```
Gutter-bar semantics: `onGutterBarClick` fires on primary press on a bar (line-decoration or virtual-row bar), from input; the press then neither moves the caret nor selects the line. Press in gutter with no bar still selects the line. `gutterBarContextMenu` opens on secondary press on a bar (closure evaluated at each open); secondary press elsewhere opens the view's own `.contextMenu` if any. `onGutterBarHover` NOT built.
Scroll sync: assigning `CodeScrollState.position` scrolls on the view's next frame and is **not** reported through `onScroll` (so two views synced via onScroll settle, no echo). `onScroll` fires after the frame for wheel/drag/clamp/edit-above shifts; runs outside frame phases (may write other state). Position is in display rows so filler-aligned diff panes stay aligned at any font/scale.

### Record docs 225 / 227 / 228 / 229: usage, limits, caveats
- **225 (buffer)**: portable, 45 tests. Added beyond proposal: `replaceSelections`, `primarySelection`, `revealSerial`, `undoByteLimit`, `CodeSnapshot.text/utf8(in:)/lineRange/...`. Perf numbers in rec 225 sec 2 (debug).
- **227 (view)**: Open cost = visible rows (13 shaped on open at 400x200, same at 1k and 100k lines; 5.6 MB/100k-line file: buffer 74 ms, first frame 12 ms debug). Shaped lines cached two frames, keyed by content; long lines (20 KB) shaped as a window. Keystroke in buffer invalidates no ancestor layout (0 measure calls). Accessibility: one `.textArea` node, value = visible rows' text capped 64 KB, built only while an a11y client is attached (headless `elements(role:)` attaches). Demo: `METALUI_CODE_DEMO=1 swift run MetalUIDemo` (`Sources/MetalUIDemoContent/CodeViewDemo.swift`: provider colouring requested rows, author bars, virtual removed rows, synced second view). **Caveats**: style is colour-only (no bold/italic); debug-build allocation pin only; Windows needs build code in separate functions (1 MB main-thread stack rule; `@inline(never)`); model construction off the main thread traps (main-actor closures).
- **228 (edit)**: Editing default ON (`codeViewEditable(true)`; existing views became editable). Keys: motions by grapheme/word/smart line start/line end/doc ends/page (with goalX); deletes by grapheme/word/to line start; Return (buffer line ending + indent); Tab/Shift-Tab (spaces or tab per `indentUsingSpaces`); copy; cut (whole line when no selection); paste (line-ending normalised); select all; undo/redo. Home/End are smart-line keys on all platforms; Page keys move the caret. **Not done**: whole-line paste above caret (VS Code behaviour). Mouse: press, shift-press, double (word), triple/gutter (line), drag by unit, drag-autoscroll. IME marked text supported (never enters the buffer/edit stream until committed; underline). Caret: 1 pt bar while focused, blinks (2 frames/s idle) unless `.off`. Control-Tab is let through the traversal stage for code views (focus-trap fix). Edits are applied in input under `StateDispatch.dispatching`; they appear on `CodeEdit` stream with origin `.typing/.paste/.deletion/.undo/.redo`. Multi-cursor: buffer supports many `selections`; whether the view's keys drive more than one is not stated in the record (the session reads the buffer's selections).
- **229 (find)**: View paints `findMatches` under selection (`theme.findMatch`) and `currentMatch` (`theme.currentFindMatch`); only shown rows' matches visited (binary search). The **find bar is the app's**: app runs `snapshot.ranges(of:options:limit:)` (O(n), on query change) and assigns `findMatches`. Key `findNext/findPrevious`: Cmd-G / Shift-Cmd-G on macOS, Ctrl-G / Ctrl-Shift-G elsewhere; wraps; selects match with `buffer.select(_, reveal: true)` (centres row in every view of the buffer); claimed ONLY while matches exist (else app `onKey` for same chord fires; with matches view claims before `onKey`; order: Keymap, `onKeyPress`, field keys, `onKey`). Works on read-only view. No F3 binding. Step from a caret inside a match skips that match; from match start takes it. `theme.currentLine` (default nil) tints caret row when nothing selected.

## 3. Image(systemName:) -- on `origin/master` only (local HEAD lacks it)
Records `docs/record/230-symbol-images.md` (PR #227, macOS) and `232-lucide-icons.md` (PR #229, Linux/Windows icons); no record 231 on master (231 = block-markdown on feat/markdown-parser). Rulings `SYM-A..SYM-O` in `docs/superpowers/2026-11-07-symbol-images-decisions.md`.
```swift
origin/master Sources/MetalUI/SymbolImage.swift:78  public init(systemName: String)          // extension Image
:84  public func symbolRenderingMode(_ mode: SymbolRenderingMode?) -> Image
SymbolEnvironment.swift:11  public enum Scale: Sendable, Hashable, CaseIterable { small, medium(default), large }   // nested in Image: Image.Scale  (confirm case list in file)
:18  public enum SymbolRenderingMode: Sendable, Hashable { monochrome, hierarchical, multicolor }   // NO .palette (SYM-M)
:30  public struct SymbolVariants: Sendable, Hashable { .none .fill .circle .square .rectangle .slash ; chainable .circle.fill }
:79  func imageScale(_ scale: Image.Scale) -> EnvironmentScope<Self>
:85  func symbolRenderingMode(_ mode: SymbolRenderingMode?) -> EnvironmentScope<Self>
:91  func symbolVariant(_ variant: SymbolVariants) -> EnvironmentScope<Self>
Icon.swift:16 public struct Icon: Hashable, Sendable { viewBox: Size<Pixels>; layers: [Layer]; init(viewBox:layers:)
:78   public static func bundled(_ systemName: String) -> Icon?   // main actor
:88   Image.init(icon: Icon, label: Text) ; :94 Image.init(decorative icon: Icon) }
```
Behaviour: size = environment font point size x `imageScale`; coloured by foreground style; `.bold()` etc. follow font weight. **macOS draws real SF Symbols** (AppKit raster cache LRU 512). **Linux/Windows draw bundled Lucide icons** (29 icons, 38 SF names mapped via `BundledSymbols.table`, e.g. `cpu` for agent, `brain.head.profile`->`brain`; `.fill` only for play/stop/star/circle/square/triangle, other `.fill` falls back to base name). A missing name is a 0x0 leaf, no log (counted in diagnostics). `robot` does not exist. Accessibility label = SwiftUI's label table. Cursor/toolbar buttons use symbols too. The local checkout still has the old `Image` (bitmap init only: `Image.init(_ bitmap: ImageBitmap, scale:, label:)`, `init(decorative:scale:)`, `resizable()`, `interpolation(_:)`). Alloy must pull master (do not do it from this session) before relying on any of this.

## 4. G6 defaultScrollAnchor and G7 FrameTiming
```swift
Sources/MetalUI/DefaultScrollAnchor.swift
:24  public struct ScrollAnchorRole: Sendable, Hashable { static let initialOffset, sizeChanges, alignment }
:176 extension ScrollView:         public func defaultScrollAnchor(_ anchor: UnitPoint?) -> Self
:188                               public func defaultScrollAnchor(_ anchor: UnitPoint?, for role: ScrollAnchorRole) -> Self
:197/:204 same two on ProposalScrollView
```
Notes (record 224): modifier is declared **on the ScrollView itself**, not an ancestor (divergence 226); first call per role wins; `nil` declares nothing. `.defaultScrollAnchor(.bottom)` alone = SwiftUI idiom for transcript: starts at the end, content shorter than viewport sits at bottom, follows the end while at the end (including `LazyVStack` windows, decided in layout so the window is at the end in the frame rows land), wheel up releases, scrolling back to the end re-engages (for `.initialOffset` role alone it never re-engages). `for: .sizeChanges` = follows but does not start at the end. Other anchors place once. Only `ScrollAxis` `.vertical`/`.horizontal` exist (`ScrollView.swift:5`, init `ScrollView(_ axis: ScrollAxis = .vertical, elementID:, content:)` :231): **no two-axis ScrollView (G5 unbuilt)**. `ScrollViewReader`/`ScrollViewProxy.scrollTo(_:anchor:)` exist (`ScrollViewReader.swift:26,125`).
```swift
Sources/MetalUI/FrameTiming.swift
:14  public enum FrameInputKind: Sendable, Equatable { key, text, pointer, wheel, other }
:32  public struct FrameTimingSample: Sendable, Equatable { frameIndex: UInt64; inputKind: FrameInputKind?; inputTimestamp: UInt64?; inputReceived: UInt64?; inputCount: Int; buildStart, layoutEnd, prepaintEnd, paintEnd, commit: UInt64; presented: UInt64?
:72    var inputToCommit: UInt64? ; :78 var inputToPresented: UInt64? ; :84 var frameDuration: UInt64 }   // all ns on FrameTiming.now() clock
:107 @MainActor public final class FrameTiming {
:108   public static let defaultCapacity = 512 ; :112 public let capacity: Int
:115   public var onFrame: (@MainActor (FrameTimingSample) -> Void)?     // after commit, outside phases; presented still nil
:118   public var onPresented: (@MainActor (FrameTimingSample) -> Void)? // only where platform reports presentation (Metal addPresentedHandler)
:135   public init(capacity: Int = FrameTiming.defaultCapacity, emitsSignposts: Bool = false)
:146   public var emitsSignposts: Bool ; :163 public var samples: [FrameTimingSample] ; :171 public var last: FrameTimingSample? ; :176 public func removeAll()
:188   public nonisolated static func now() -> UInt64 }
Window.swift:457  public var frameTiming: FrameTiming? = FrameTiming.fromEnvironment()   // METALUI_SIGNPOSTS=1 env => signposts on
```
Notes (record 222, `docs/frame-timing.md`): zero cost off, zero allocation on in steady state; never written from a phase; macOS `OSSignposter` under subsystem `com.metalui` (Instruments); `inputTimestamp` falls back to receive time when platform clock differs (SDL, harness). `Window.frameTiming` is on `Window`, so Alloy needs the `Window` reference (headless: `TestWindow.window.frameTiming`). `FrameTimingTests` portable. Benchmark recipe in record 227 sec 7.5 (release build, `METALUI_CODE_DEMO=1 METALUI_SIGNPOSTS=1 swift run -c release MetalUIDemo`).

## 5. Existence matrix (local HEAD)
| Feature | Status | API / location |
|---|---|---|
| Block markdown view (G2) | **NO view.** Parser only on branch `origin/feat/markdown-parser` (target `MetalUIMarkdown`: `MarkdownDocument(init(), init(parsing:), append(_:), blocks, version)`, `MarkdownBlock{id,kind}`, `.Kind` paragraph/heading/codeBlock(language:code:isClosed:)/blockQuote/list/thematicBreak/table; streaming append; no task lists). `MarkdownView`/theme/code fences/tables are "PRs 3-4, not started". Inline markdown exists on master: `Sources/MetalUI/MarkdownInline.swift` (Text(LocalizedStringKey)). |
| Tab view / tab strip (G4) | **NO.** No TabView/DisclosureGroup/Label/sheet. Segmented `Picker` exists: `PickerStyle.segmented` (`Picker.swift:22`); `Picker(_ title, selection: Binding, content)` :119/:126, `.pickerStyle(_)` :148. |
| Popover | YES `Popover.swift:264` `popover(isPresented: Binding<Bool>, attachmentAnchor: PopoverAttachmentAnchor = .rect(.bounds), arrowEdge: Edge? = nil, @ElementBuilder content:) -> PopoverModifier`; item-binding :278. Dismiss on outside press / Esc; press on popover never reaches beneath; content `@State` fresh per presentation. Chrome with arrow. |
| Anchored overlay (autocomplete list) | YES, MetalUI-only `AnchoredOverlay.swift:99` `anchoredOverlay(isPresented: Binding<Bool>, at point: Point<Pixels>, in space: CoordinateSpace = .local, anchor: UnitPoint = .topLeading, @ElementBuilder content:) -> PopoverModifier<Self,P>`; item variant :111. **No chrome** (no panel/border/shadow/padding: supply your own), point read fresh each layout (`.local` = declarer's space, `.global`, `.named`), flips to mirrored anchor if it would leave the window then clamps; dismiss on any outside press (press on the declarer is NOT consumed) and on Esc even while a field inside is focused; a press/wheel/drop on it never reaches beneath; **keys reach a focused field inside it**. UNVERIFIED: whether showing it steals focus from a CodeView (it is a separate presentation layer; check before relying; Alloy likely needs onKeyPress on the editor to drive up/down/enter while the overlay is shown). Dismiss-on-outside-press writes `isPresented=false` from input. |
| contextMenu | YES `ContextMenu.swift:70` `contextMenu(@MenuContentBuilder menuItems: () -> M)`; :86 variant with `(Point<Pixels>?)` location. `Menu(_ title, @MenuContentBuilder content:)` `MenuContent.swift:180,~207`; `Divider: MenuContent` :107. |
| Pasteboard | YES `Clipboard.swift:79` `struct Clipboard` via `Window.clipboard` (:159): `write<T: Transferable>(_:) -> Bool` :90, `write(_ items: [T])` :99, `read<T>(_ type:) -> T?` :108, `readAll` :114, `itemCount` :120, `contentTypes: [String]` :124, `hasContent(of: ContentType)` :127. Modifiers `copyable/cuttable/pasteDestination` (`ClipboardModifiers.swift:29,39,55`), `PasteButton` (`PasteButton.swift:26`, `init(payloadType:onPaste:)`, `init(supportedContentTypes:...)`). **Images:** no `ContentType.png/.image` constants (Transferable.swift has item/data/text/plainText/utf8PlainText/url/fileURL/json/directory/folder only); build one with `ContentType("public.png", conformingTo: [.data])` and `Data` is `Transferable` (exports `[.data]` only), so a custom `Transferable` type listing `public.png`/`public.tiff` in `importedContentTypes()` is needed to read an image off the clipboard; `Clipboard.contentTypes`/`DropItem` give raw identifiers. Not verified end-to-end for images on AppKit. |
| Drag and drop of files onto a view | YES (internal + external). `DragAndDrop.swift:139` `draggable(_:)`, :160 `dropDestination<T: Transferable>(for:action: (items:[T], location: Point<Pixels>) -> Bool, isTargeted: (Bool)->Void = {_ in})`; `DropDelegate.swift:80` protocol + :115 `onDrop(of types: [ContentType], delegate: any DropDelegate) -> Self` (`DropInfo.location`, `hasItemsConforming(to:)`, `itemProviders(for:) -> [DropItem]` to `DropItem.load`). External (Finder) drags work (`DragSession.dispatchExternalDrop`); on SDL external hover items unknown until performDrop (`hasItemsConforming` returns true, providers empty). Files: `URL` is Transferable (imports `.url/.fileURL`, `Transferable.swift:199`), so `.dropDestination(for: URL.self) { urls, pt in ... }`. Harness: `TestWindow.drop(_ items: [DropItem], at:)` (TestWindowInput.swift:158). |
| Keyboard shortcuts / key presses | YES. `onKeyPress(_ key: KeyEquivalent, action: () -> KeyPress.Result)`, `(_ key, phases:, action: (KeyPress)->Result)`, `onKeyPress(keys:phases:action:)`, `(characters: CharacterSet,...)`, `(phases:action:)` `KeyPress.swift:225-261` (also on proposal path `KeyboardModifier.swift:27-55`). `KeyPress{phase,key,characters,modifiers: EventModifiers}`; `Result {handled, ignored}`. `onKey(_ handler: (KeyEvent) -> Bool)` `Box.swift:821`. `Button.keyboardShortcut(_ key: KeyEquivalent, modifiers: EventModifiers = .primary)` `Button.swift:351` (+ `KeyboardShortcut` overloads). App commands `Commands.swift:383` `commands { }`. Key order: Keymap, onKeyPress, field keys, onKey, button shortcut, commands, Tab traversal. `.primary` = Cmd on macOS, Ctrl elsewhere. |
| Focus | YES. `FocusState<Value: Hashable>` (`FocusState.swift:57`; `init()` Bool, `init<T>() where Value == T?`), `.focused($state)` :199, `.focused($state, equals:)` :206, `focusable(_:)` `Box.swift:788`, `focusable(_:interactions:)` (`FocusInteractions` activate/edit/automatic). Writing a focus state moves focus only to an element focusable last frame; write from input, never a phase. Click-to-focus (rec 214), initial focus (rec 215). `Window.focus(_ id: GlobalElementID?)` `Window.swift:705`. |
| TextField | `TextField.swift:26`; controlled: `init(_ placeholder: String, text: Binding<String>)` :87, `init(_:text:onChange:)` :69, with `selection: Binding<TextSelection?>` :97; `.font(family:size:)`, `.foregroundColor`, `.textFieldStyle(_)`, `.onSubmit(_ action)` :165. Single line. |
| TextEditor (multi-line) | `TextEditor.swift:43`; `init(_ placeholder = "", text: Binding<String>)` :102, `(.. selection: Binding<TextSelection?>)` :112, `(text: String, onChange:)` :84; `.font`, `.foregroundColor`, `.textEditorStyle(_)` (`.plain` drops the opaque background+focus ring). Return inserts newline; **Cmd-Return (Ctrl-Return off macOS) is passed through** (not an editing key), so commit via `onKeyPress(keys:[.return]) { press.modifiers.contains(.command/.control) ? commit() : .ignored }` (example in the file header, `TextEditor.swift:12-24`). Wraps; caret, selection, IME, clipboard, undo. No submit callback of its own. |
| Sheets | **NO `.sheet`**. Alerts: `Alert.swift:194` `alert(_ title, isPresented: Binding<Bool>, actions)`, :202 with `message:`, :215/:226 `presenting:`; `confirmationDialog` :248/:259 (AppKit NSAlert sheet; SDL draws in-window). File dialogs `FileDialogs.swift:233,251` `fileImporter(isPresented:allowedContentTypes:allowsMultipleSelection:onCompletion:)`, `fileExporter` :283; `ContentType.folder` chooses folders on AppKit. |
| Menu / Picker | `Menu` yes (`MenuContent.swift:180`); `Picker` yes (`Picker.swift:81`, styles automatic/menu/segmented/radioGroup/inline); `Toggle`, `Slider`, `Stepper`, `ColorPicker`, `ProgressView`, `List`, `Grid`, `LazyVStack/LazyVGrid`, `HSplitView/VSplitView` (`SplitView.swift:357,403`), toolbar, tooltips exist. |
| DisclosureGroup / collapse | **NO.** Roll your own with Button + conditional content. |
| File-system watching | **NONE** in Sources/MetalUI*, MetalUIPlatform or MetalUIAppKit (no FSEvents/DispatchSource). App owns it (feed `buffer.applyExternalReplacement(_, expectingVersion:)`). |

## 6. MetalUITesting headless harness (`Sources/MetalUITesting`, docs/testing.md)
Runs real `Window` over `HeadlessPlatform` + a recorded `Scene`; no screen/GPU; works macOS/Linux/Windows. Non-Apple needs a text system (tests use `harnessTextSystem`, `Tests/MetalUITestingTests/HarnessSupport.swift:43` `harnessWindow(size:colorScheme:scaleFactor:options:recordsLayout:_ content:)`).
- Host: `TestWindow(size:colorScheme:scaleFactor:options:recordsLayout:textSystem:content:)` (`TestWindow.swift:71`, throws) or `TestApp(textSystem:)` (`TestApp.swift:35`) then `openWindow(title:size:...content:)` :62. `content` returns an `Element` (CodeView is one).
- Clock/frames: `tick()` :112, `advance(by:)` :124, `advanceFrames(_:)` :130, `runUntilIdle() async` :159, `runUntil(timeout:_:) async` :199 (use this, not fixed idle counts), `window.setNeedsRedraw()`, `resize(to:)` :221, `setScaleFactor`, `setAppearance`, `close()`.
- Input (`TestWindowInput.swift`): `click(at:modifierFlags:)` :14, `doubleClick`, `rightClick`, `hover(at:)`, `scroll(at:byDeltaX:deltaY:)` :67, `drag(from:to:steps:)` :100, `click(at:forDuration:thenDragTo:)`, `magnify`, `rotate`, `drop(_ items: [DropItem], at:)` :158, `typeText(_:)` :171, `typeKey(_ key: KeyEquivalent, modifierFlags:)` :182, `pressModifiers`; raw `send(_ event: InputEvent) -> Bool` :214. By element: `click(_ element: TestElement)`, `typeText(_:into:)`, etc. (`TestWindowElementInput.swift`). IME: `setMarkedText/commitMarkedText/cancelMarkedText` (`TestWindowInputMethod.swift`). Clipboard: `setClipboard(_ item:)`, `setClipboard(text:)`, `clipboardRepresentations`, `clipboardItems` (`TestWindowClipboard.swift`). Presentations: `presentedAlert`, `respondToAlert(button:)`, `presentedMenu`, `chooseMenuItem(_ path: String...)`, `presentedFileDialog`, `respondToFileDialog(choosing:)`.
- Reading: `element(identifier:)`, `element(label:)`, `elements(role: .textArea)` (TestWindowQueries.swift:25-48, `TestElement` has role/label/value/frame/isFocused...; CodeView exposes one `.textArea` whose `value` = visible rows' text, capped 64 KB), `focusedElement`, `frame(ofID:)` (needs `.accessibilityIdentifier`/ID), `scene` (`Scene`, `scene.rects` with `.bounds/.background`; glyph colours; used to assert caret bar = rect 1pt wide x pitch tall), `lastFrameWork`/`frameWork: [FrameWork]` (counters: `codeLinesShaped`, `codeLinesPainted`, `codeGlyphsEmitted`, `codeHighlightRunsVisited`, `codeFindMatchesVisited`, build/layout counts, `FrameWork.swift`). There is no "give me the rendered text as a string" call other than the a11y node value / buffer snapshot / scene.
- Example (`Tests/MetalUITestingTests/CodeViewEditingTests.swift:19-55` and `CodeViewTests.swift:43`):
```swift
@MainActor func codeWindow(buffer: CodeBuffer, decorations: CodeDecorations, width: Float = 400, height: Float = 200,
                           scale: Float = 1, numbers: Bool = true) throws -> TestWindow {
    try harnessWindow(size: sz(width, height), scaleFactor: scale) {
        CodeView(buffer: buffer, decorations: decorations).font(size: 12).showsLineNumbers(numbers) } }
@Test @MainActor func typingEditsTheBufferAndTheCaretFollows() throws {
    let buffer = CodeBuffer("hello\nworld\n")
    let window = try codeWindow(buffer: buffer, decorations: CodeDecorations(buffer: buffer), height: 200, numbers: false)
    window.click(at: pt(60, 6))                       // focus the view
    buffer.selections = [CodeSelection(caret: 0)]; window.window.setNeedsRedraw(); window.tick()
    window.typeText("ab")
    #expect(buffer.snapshot().text == "abhello\nworld\n")
    #expect(buffer.primarySelection == CodeSelection(caret: 2))
    #expect(window.scene.rects.filter { $0.bounds.size.width == 1 }.count == 1)   // the caret bar
}
```
Other code tests: `CodeViewTests.swift`, `CodeViewVirtualRowsTests.swift`, `CodeViewFindTests.swift`, `CodeViewImeBlinkTests.swift`; `Tests/MetalUICodeBufferTests`. Use `.codeCaretBlink(.off)` for deterministic scenes. Helper names `pt(x,y)`, `sz(w,h)`, `codePitch(scale:)` are test-local (HarnessSupport / CodeViewTests).

## 7a. docs/guides/
- `README.md` index of task-led guides (also links Jotter sample app `Examples/Jotter`).
- `cross-platform.md` how to run on Linux/Windows (SDL3 backend, portable text, images/fonts, packaging).
- `drawing-and-gpu.md` shapes/paths/gradients/shadows/materials and GPU surfaces; where the model differs from SwiftUI.
- `input.md` clicks/gestures/keys/text: click-to-focus, single gesture arena, key pipeline, TextField selection.
- `layout.md` stacks/frames/Grid, Row/Column/Box legacy, proposal path.
- `presentations-and-app-shell.md` popover, menu, alert, file dialogs, toolbar, window/app shell; native vs window-drawn.
- `state-and-identity.md` @State/Binding/@Observable/@Environment and identity (position and `.id`).
Other top-level docs: `docs/api-overview.md` (reference), `docs/divergences.md`, `docs/testing.md`, `docs/frame-timing.md`, `docs/getting-started.md`, `docs/migration.md`, `docs/packaging.md`, `docs/practices/`, `docs/rules/`, `docs/verification/human-checks.md`, `docs/probes/`, `docs/superpowers/*decisions.md` (rulings per prefix, e.g. `2026-11-07-code-view-decisions.md` with CV-A..CV-AE).

## 7b. docs/record 200+ (local HEAD; origin/master adds 230, 232)
200 layer tagged sRGB; 201 AnyElement type swap resets; 202 default-spacing probe/row 89; 203 default spacing at text edge; 204 default cross-fade, Animatable, glass-morph probes; 205 removal ghost position; 206 default fade; 207 leaver moves as it fades; 208 public Animatable on shapes/keyframes; 209 Component & Animatable; 210 segmented Picker sizing; 211 replayed leaver; 212 line-height row 86; 213 hierarchical styles; 214 click-to-focus; 215 initial focus; 216 clickable text links; 217 ViewThatFits; 218 group opacity (offscreen group pass); 219 shadow/blur over group texture; 220 shape clips as masked groups; 221 gradient foregroundStyle on text; 222 frame timing and signposts (G7); 223 text under transforms (text zoom); 224 defaultScrollAnchor (G6); 225 code buffer (G1 PR1); 226 continuous rounded corners; 227 read-only code view (G1 PR2); 228 editing in the code view (G1 PR3); 229 find matches in the code view (G1 PR4). origin/master: 230 symbol images (G3 PR0-1); 232 bundled Lucide icons (G3 PR2). origin/feat/markdown-parser: 231 block Markdown parser (G2 PR1-2).
