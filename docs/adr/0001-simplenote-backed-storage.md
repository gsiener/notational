# ADR 0001: Simplenote-backed storage replaces the notes database

- Status: accepted
- Date: 2026-09-30
- Issues: #1 (absorbs #3); shrinks #9 and #2
- Research: [docs/research/simplenote-sync.md](../research/simplenote-sync.md)

## Context

nvALT stored notes in a custom single-file database (`Notes & Settings`: keyed archive, zlib, optional AES with PBKDF2 keys and per-save salts) plus a custom write-ahead journal, with optional one-file-per-note storage modes and a Simplenote sync layer bolted on. About 3,200 lines re-implemented durability, crash recovery and encryption that the platform already provides, and persistence depended on sync types.

The maintainer treats **Simplenote as the source of truth** across several Macs. A spike showed a third-party client can authenticate without an API key using Simplenote's email-code login while honestly identifying itself (`request_source: "nvalt"`), and read the account through the Simperium HTTP API.

## Decision

1. **Local storage is a SQLite replica of the Simplenote account** (system `libsqlite3`). One row per note: verbatim `content`, `tags`, `deleted`, dates, the full last server JSON, last confirmed version, pending flag; plus the bucket sync point (`cv`). No journal, no archive format, no app-level encryption (FileVault covers the disk).
2. **The one-file-per-note storage modes are removed.** Folders of notes can be imported once; notes leave as files via Export. nvALT works without signing in (local-only: the replica never syncs).
3. **Sync uses Simperium HTTP and lets the server merge text.** Push = `POST note/i/<id>/v/<last confirmed version>` with the full note; adopt the returned merged note and version. Pull = full index on first sync, then `note/changes?cv=`. No client-side diff-match-patch or JSON-diff.
4. **Login is the key-less email-code flow** identifying as `nvalt`; the sync token lives in Keychain; a 401 means sign in again. No API keys are shipped or borrowed.
5. **Delete means Simplenote's trash** (`deleted: true`). Trashed rows stay local, hidden. nvALT never purges permanently.
6. **Three modules:** *Notes store* (SQLite, tested against a temp file), *Sync engine* (deep: first sync, catch-up, pushes, trash, re-index, retry), and a *Simplenote port* with two adapters: HTTP (production) and an in-memory fake server (tests).
7. **Threading:** the main thread owns in-memory `NoteObject`s (search stays in memory); the store and the sync engine each run on their own serial queue; remote changes reach the UI as one batched main-thread update.
8. **The open note is protected while typing:** pushes repeat until the user pauses; merged text is applied as a minimal range edit that preserves the selection and undo.
9. **Field mapping:** title/body are derived from verbatim `content` and recombined with the note's original separator (unchanged notes round-trip byte for byte); labels ↔ `tags`; every other field (`systemTags`, `shareURL`, `publishURL`, future fields) is preserved untouched.
10. **Migration:** first launch downloads the whole account. The old database and journal are left untouched as a backup; any notes in them that were never synced or have unpushed edits are imported as new notes tagged `nvalt-recovered`. Still-relevant settings (body font, text color, delete confirmation, secure text entry) move to app preferences.
11. **Timing policy stays in `NotationController`** (existing debounce timers); the store itself is synchronous from its caller's point of view.

## Consequences

- Deletes `FrozenNotation`, `WALController`, `DeletedNoteObject`, the old sync classes (`SimplenoteSession`, `SimplenoteEntryCollector`, `SyncResponseFetcher`, `SyncSessionController`, `NotationSyncServiceManager`, sync mixins, `InvocationRecorder`), BSJSON, the passphrase and key-derivation UI, per-file storage (`NotationDirectoryManager`, most of `NotationFileManager`), and most `FSRef` use.
- Encrypted nvALT databases can no longer be opened by the new storage; such a database would need the old app to export first.
- Depends on Simplenote continuing to allow this third-party identity; Simplenote Help says third-party clients can be blocked. If blocked, nvALT keeps working local-only.
- Earlier design decisions for #1 that assumed keeping the old format (store-owned encryption with opaque prefs fields, a passphrase port, a store-owned `NVStoredNote` protocol) are **superseded** by this ADR and should not be re-proposed.
