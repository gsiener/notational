# External-editor lifecycle evaluation (issue #45)

**Superseded 2026-10-04:** the owner will never use an external editor, so the whole feature was removed instead of reduced: ODBEditor, `ExternalEditorListController`, the "Edit With" menus, the External Text Editor preference and the note-side editing sessions. This report is kept as history.

## Evidence and decision

Keep ODB editing for now. `NoteObject` starts sessions and imports modified-file callbacks; `ODBEditor` sends the ODB open event and receives modified and closed events. `ExternalEditorListController` includes BBEdit (`com.barebones.bbedit`) among its compatible editors. The 468-line bundled ODB source therefore serves a live feature, not dead code. No replacement or retirement is approved.

On this checkout's host, `/Applications` and `~/Applications` contain no visibly named BBEdit, TextMate, CotEditor, MacVim, or SubEthaEdit app; Spotlight bundle-ID queries for BBEdit and TextMate returned no paths. This is an availability check, not proof that no compatible editor exists elsewhere. A live ODB edit/save/close round-trip was not run, to avoid starting a GUI editor during concurrent agent work.

## Behavior matrix

| Case | Current ODB path | Native open plus watching would need |
| --- | --- | --- |
| Normal save | Editor sends `FMod`; `NoteObject` reads the temp path and schedules a store write. | Observe the write, read a complete snapshot, and suppress duplicate imports. |
| Atomic save | Callback reads the pathname after replacement, so it can import the new inode. Covered by `NoteObjectTests`. | Watch the parent directory or reattach after replacement; an inode-only watcher can miss later saves. |
| Save As / rename | ODB supplies an optional new location. `NoteObject` currently reads the original path and does not follow the new path. Covered as existing behavior, not parity. | Define whether Save As ends the note session or follows the new file, then retain the original temp-file cleanup path. |
| External deletion | A missing path fails import and leaves note content intact. Covered by `NoteObjectTests`. | Treat deletion as a missing edit, not an empty note, and decide how to finish the session. |
| Concurrent local change | A later `FMod` imports the entire temp file, replacing the local note body. No conflict detection exists in this path. Covered as current behavior by `NoteObjectTests`. | Track the note revision at session start and decide merge/conflict policy before importing. |
| Close and cleanup | `FCls` calls `NoteObject` to remove the temporary file and removes the session record. Covered at the note callback. | Supply an equivalent close/abandon signal. File watching alone has no document-close event; a timeout can discard late edits. |
| Failed open | Launch and Apple-event failures return `NO` without registering a session. Generated note and string files are removed; `editFile:` leaves the caller's original file intact. Deterministic tests cover both failures. | Surface open failure and remove only files owned by the editing session. |

`NSWorkspace` can choose and open an editor, but it does not provide the ODB save and close callbacks. A native replacement would need directory monitoring, atomic-replacement recovery, import debouncing, session ownership, conflict handling, and an explicit close/cleanup policy. That is not yet a demonstrated reduction in code or risk.

## Manual compatibility check for an isolated GUI session

Install or locate one currently supported ODB editor, preferably BBEdit. In a disposable local-only note, use **Edit in BBEdit**, save once, save again with an atomic-write setting if available, use Save As, and close. Confirm the note updates after each intended save, the temp file disappears after close, and an unrelated local edit is handled according to a chosen conflict policy. Repeat with external deletion and with the app closing while the editor remains open. Record editor and macOS versions and the exact temp-file path. Do not use a shared account note for this check.
