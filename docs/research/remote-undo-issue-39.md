# Remote update and selected-editor Undo (#39)

## Reproduction on `17d9f92`

`AppControllerRemoteUndoTests` constructs the real `LinkingEditor`, selects a `NoteObject`, inserts ` local` through the editor, and applies a newer `NVNoteRecord`. The editor shows `one local\nTWO`, but its note-owned undo manager changes from `canUndo == YES` to `canUndo == NO`. The test covers the actual `applyNoteRecord:` → `updateWithSyncBody:andTitle:` → `contentsUpdatedForNote:` path. It is a characterization test; it deliberately asserts the current failure so CI stays green while a safe fix is developed.

The model clears Undo in `NoteObject.m` when the remote body is applied. `AppController.m` then uses `NVTextMerge` to replace the changed range in the selected editor and map its selection. The editor's `textDidChange:` route calls `setContentString:`, which dirties the note and schedules a write; remote updates must continue to bypass that route. The model's remote route separately refreshes the search cache and preview, while `applyNoteRecord:` updates title, labels, and modified date.

## Policy needed for implementation

An Undo action created by AppKit has ranges in the pre-merge text. Preserving that action object after an unrelated remote insertion can make its range point to the wrong text. Removing only `removeAllActions` is therefore unsafe.

Capture local editor transactions as reversible text changes, including their pre-edit text and selection. When a remote record arrives, rebase each still-valid local transaction over the remote delta before installing the merged body. Undo must remove the local contribution while retaining nonoverlapping remote text; Redo must restore it. When local and remote changes overlap, Undo should reveal the server's remote contribution, and Redo should restore the merged local-winning result. This overlap rule needs product confirmation if a different outcome is desired. Each Undo or Redo is a local edit and may schedule one write; applying the remote record itself must schedule none. Recompute selection from the resulting text after each operation.

Exercise at least: remote insertion before the local edit, remote edit after it, same-line overlap, multiple local Undo groups, Unicode ranges, selection inside and after the changed region, title and label changes, search cache and preview refresh, and no echo write. These must run through the selected editor, not only `NVTextMerge`.

## Integration boundary

Issue #38 owns persistence APIs. Its caller changes to `NotationController` record application and `NoteObject_NVRecord` must land before this work is integrated. Keep remote-update and editor-Undo coordination in the UI/model path; do not redesign store or sync APIs here. `NotationController.m`'s `didUpdateNotes:` call to `applyNoteRecord:` and its `contentsUpdatedForNote:` callback are the likely overlap points to recheck after #38.

No production behavior changed in this exploration. A macOS manual check remains: edit a selected note, receive a remote update, invoke Undo and Redo, and verify selection plus absence of a remote echo push with a real account.
