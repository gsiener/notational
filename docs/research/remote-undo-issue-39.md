# Remote update and selected-editor Undo (#39)

## Reproduction on `17d9f92`

`AppControllerRemoteUndoTests` constructs the real `LinkingEditor`, selects a `NoteObject`, inserts ` local` through the editor, and applies a newer `NVNoteRecord`. On the baseline, the editor showed `one local\nTWO`, but its note-owned undo manager changed from `canUndo == YES` to `canUndo == NO`. The regression suite now requires Undo and Redo to work across this path.

The model clears Undo in `NoteObject.m` when the remote body is applied. `AppController.m` then uses `NVTextMerge` to replace the changed range in the selected editor and map its selection. The editor's `textDidChange:` route calls `setContentString:`, which dirties the note and schedules a write; remote updates must continue to bypass that route. The model's remote route separately refreshes the search cache and preview, while `applyNoteRecord:` updates title, labels, and modified date.

## Implemented policy

An Undo action created by AppKit has ranges in the pre-merge text. Preserving that action object after an unrelated remote insertion can make its range point to the wrong text. Removing only `removeAllActions` is therefore unsafe.

The selected editor records each local text-change state. When a remote record changes its body, `AppController` rebases these states over the remote result with `NVTextMerge`, removes the old AppKit range actions, and installs one state transition per Undo step. The selected editor keeps valid Undo and Redo; an unselected note discards stale range actions. Selection follows each minimal text transition. Remote record application does not call the local edit path or schedule a write; Undo and Redo are local edits and do write.

The overlap rule is **remote wins during Undo**: if a remote update and a local edit changed the same line, Undo retains the remote line. Redo restores the server's merged line. This follows the line-level merge policy in `NVTextMerge` and avoids inventing a character-level resolution for conflicting edits. The regression suite covers this choice explicitly.

The suite covers a remote insertion before a local edit, a remote edit after it, same-line overlap, multiple local Undo groups, a second remote update after Undo, selection mapping, title and label changes, search cache and preview notifications, and no echo write. The existing `NVTextMergeTests` cover Unicode range handling. A real-account manual check is still required for live sync timing and AppKit's event grouping while typing.

## Integration boundary

Issue #38 owns persistence APIs. Its caller changes to `NotationController` record application and `NoteObject_NVRecord` must land before this work is integrated. Keep remote-update and editor-Undo coordination in the UI/model path; do not redesign store or sync APIs here. `NotationController.m`'s `didUpdateNotes:` call to `applyNoteRecord:` and its `contentsUpdatedForNote:` callback are the likely overlap points to recheck after #38.

A macOS manual check remains: edit a selected note, receive a remote update, invoke Undo and Redo, and verify selection plus absence of a remote echo push with a real account.
