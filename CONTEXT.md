# nvALT domain glossary

Terms used in code, issues and reviews. Keep names here in sync with the code.

**Note** — one titled body of text with labels, dates and a stable UUID (`NoteObject`). The unit the user creates, searches and edits.

**Notation folder** — the folder the user chose to hold their notes (default `~/Library/Application Support/Notational Data`). Stored in user defaults as `DirectoryAlias`.

**Storage format** *(legacy)* — how the old app kept notes: the *single database* (default), or one file per note as plain text, RTF or HTML (`notesStorageFormat`). Removed by ADR 0001.

**Notes database** *(legacy)* — the `Notes & Settings` file in the notation folder: a keyed archive of every note, deleted-note records and the notation settings, compressed and optionally encrypted (`FrozenNotation`). Written in full on flush or quit.

**Journal** *(legacy)* — the write-ahead log `Interim Note-Changes` in `~/Library/Caches/net.elasticthreads.nv`. Every note change is appended here first; a journal left over at launch means the last session didn't flush, and its records are merged back into the notes (newest LSN per UUID wins). `WALStorageController` writes it, `WALRecoveryController` reads it.

**LSN** — log sequence number on a note; incremented on each change so the journal and sync can tell which copy is newer.

**Deleted-note record** — a tombstone (`DeletedNoteObject`) kept so deletions reach the journal and sync services.

**Notation settings** — per-database settings stored inside the notes database (`NotationPrefs`): storage format, encryption, key derivation parameters, sync accounts, allowed file types. Distinct from **app preferences** (`GlobalPrefs`, user defaults).

**Passphrase / master key** — when the database is encrypted, the user's passphrase is stretched with PBKDF2-HMAC-SHA1 into a master key; a verifier key derived from it checks the passphrase; each save uses a fresh session salt for AES-256-CBC.

**Simplenote** — the user's source of truth across machines, reached via the Simperium API (app `chalk-bump-f49`, bucket `note`). Legacy code calls it sync service `SN`.

**Notes store** *(planned, #1, ADR 0001)* — the SQLite replica of the user's Simplenote account: one row per note with verbatim content, tags, trash flag, dates, last server JSON, last confirmed version and pending flag, plus the sync point. Replaces the notes database and journal.

**Sync engine** *(planned)* — the deep module that keeps the Notes store and Simplenote in step: first sync, catch-up from the sync point, pushing pending notes, adopting server-merged results, trash, re-index, retry.

**Simplenote port** *(planned)* — the seam between the Sync engine and Simplenote, with an HTTP adapter (production) and an in-memory fake server (tests).

**Sync point (`cv`)** — Simplenote's change version for the whole account; catch-up asks for changes after it.

**Confirmed version** — the last version of a note the server acknowledged; pushes are based on it so the server can merge concurrent edits.

**Pending note** — a note with local edits not yet confirmed by Simplenote.

**Trash** — Simplenote's `deleted: true`. Deleting in nvALT moves a note to the trash; only Simplenote's own apps purge permanently.

**Recovered note** — a note from an old nvALT database that never reached Simplenote, imported on migration with the tag `nvalt-recovered`.

**Local-only mode** — nvALT used without signing in to Simplenote; the Notes store simply never syncs.
