# Tint my own edits: design

The user approved this on 2026-11-26 ("approved, go ahead"). It is a small change.

## Why

Alloy tints agent edits so you can see who changed what. The user wants the option to see their own changes too: what
they've typed since the last save, in the code editor and in the CSV Table view. They want to choose the colour.

Today the two views disagree:
- The code editor marks your *saved* edits in the "you" colour until you Keep them.
- The Table view never tints your edits.

## Decided by the user

- **Setting:** Settings › Editor › "Tint my own edits". **Off by default.**
- **Colour:** when the toggle is on, the user can pick the tint colour. Until they pick one, it is the theme's "you"
  colour (theme slot `userAuthor`). A picked colour holds across theme switches until it is reset.
- **What is tinted:** what you typed, pasted or deleted since your last save, in the code editor and in Table view.
  The tint clears when you save.
- **With the toggle off:** none of your edits are tinted, saved or unsaved. In the code editor this replaces today's
  marks on your saved edits.

## Unchanged

- Agent and outside edits keep their tints and Keep/Revert exactly as now.
- Your edits are still recorded in the ledger as `.user`, so attribution, overlap warnings and Revert of agent edits
  all keep working. Only the colour changes.

## Approaches

- **Picked:** diff the buffer against the document's saved snapshot off the main thread, after a short typing pause.
  - The code editor shows the result under its own decoration owner, the same pattern as the git gutter marks
    (`GitDocumentMarks`).
  - The table uses byte spans, the same way it maps ledger ownership.
  - Nothing runs while idle or with the setting off.
- **Rejected: marking each keystroke's range directly.** It needs edit-range plumbing that nothing else uses, and it
  goes wrong on undo back to the saved text.
- **Rejected: recording unsaved edits in the ledger.** The ledger is the record of saved changes, and putting unsaved
  ones there would break Keep/Revert semantics.

## Constraints

- **Zero idle CPU:** nothing runs while idle or with the setting off.
- **Typing:** the diff runs off the main thread after a 0.3 s pause. It must not add body reruns or element requests to
  typing frames.
- **Large files:** the size limit is the same as git marks (`GitGutterMarks.sizeLimit`). Above it there is no tint and
  no work.

## Left to the builder

- Decoration priority, and where the per-view owner object lives.
- Accessibility tokens and ids, which follow existing patterns.
