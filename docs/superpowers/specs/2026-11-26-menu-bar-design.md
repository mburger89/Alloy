# Menu bar for the basic commands: design

Requested by the user on 2026-11-26: "add menu bar buttons for all of the basic keyboard commands like open file and
save". They chose a regular Open File on ⌘O, and raised no objection to the rest of the proposed layout.

## Why

Several everyday shortcuts work only from the keyboard: ⌘S, ⌘P, ⌘N, ⌘T, ⌘W, ⌃Tab, ⌘1–9 and ⌘F/⌘G. Nobody can discover
them, and there is no way to click them. Alloy also has no Open File command.

## Layout (new commands marked ✚)

- **File**
  - New Session ⌘N, New Terminal Tab ⌘T
  - ✚ Open… ⌘O
  - Quick Open ⌘P
  - Close Tab ⌘W, ✚ Close Window ⇧⌘W, Save ⌘S, ✚ Save As… ⇧⌘S, ✚ Save All ⌥⌘S. **This group waits for MetalUI's
    `.saveItem` placement** (requested 2026-11-26). Until then ⌘S and ⌘W keep working as they do now.
- **Edit:** MetalUI's Undo/Redo and pasteboard items, then a **Find** submenu: Find… ⌘F, Find Next ⌘G, Find Previous
  ⇧⌘G, Find in Files ⇧⌘F, Replace in Files ⇧⌘H. The last two move here from View.
- **Go, View, Git:** unchanged, except that Find/Replace in Files leave View.
- **Window:** after MetalUI's Minimize/Zoom group come Next Tab ⌃Tab, Previous Tab ⌃⇧Tab, and Go to Tab 1–9 (⌘1–⌘9).

## Rules

- **Shortcuts:** every item shows its shortcut, follows the user's keymap overrides, and is disabled when it can't run.
  Each shortcut has one owner: a command that moves into a menu gives up its hidden global key, so no element remains per
  frame.
- **Open…:**
  - A system open dialog. Multiple selection is allowed and any file type can be picked.
  - Each chosen file opens in a tab. A file outside the project opens exactly as `alloy <file>` opens one.
  - The dialog starts in the project folder once MetalUI offers a default directory, which has been requested. Until
    then it starts in the system's default folder.
- **Find…, Find Next and Find Previous** act on the focused code view's find bar, as ⌘F does today, and are disabled with
  no code view focused.

## Approaches

- **Picked:** register everything in the existing command registry (`BuiltinCommands`) with menu placements, and generate
  the menus in `AppCommands`. That is the existing pattern, and it keeps palette, keymap and menus consistent.
- **Rejected:** hand-written menu items. They would bypass keymap overrides and the palette.
- **Rejected:** putting Save and Close after `.newItem` now. The standard Close ⌘W would clash with Close Tab, and there is
  no SwiftUI-aligned place for Save. So this waits for `.saveItem`.

## Left to the builder

- Accessibility ids, following the existing `menu-*` style.
- The exact enabled predicates.
