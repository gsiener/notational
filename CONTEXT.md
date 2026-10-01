# nvALT domain glossary

Terms used in code, issues and reviews. Keep names here in sync with the code.

**Note** — one titled body of text with labels, dates and a stable UUID (`NoteObject`). The unit the user creates, searches and edits.

**Notation folder** — the folder the user chose to hold their notes (default `~/Library/Application Support/Notational Data`). Stored in user defaults as `DirectoryAlias`.

**Storage format** — how notes live in the notation folder: the *single database* (default), or one file per note as plain text, RTF or HTML (`notesStorageFormat`).

**Notes database** — the `Notes & Settings` file in the notation folder: a keyed archive of every note, deleted-note records and the notation settings, compressed and optionally encrypted (`FrozenNotation`). Written in full on flush or quit.

**Journal** — the write-ahead log `Interim Note-Changes` in `~/Library/Caches/net.elasticthreads.nv`. Every note change is appended here first; a journal left over at launch means the last session didn't flush, and its records are merged back into the notes (newest LSN per UUID wins). `WALStorageController` writes it, `WALRecoveryController` reads it.

**LSN** — log sequence number on a note; incremented on each change so the journal and sync can tell which copy is newer.

**Deleted-note record** — a tombstone (`DeletedNoteObject`) kept so deletions reach the journal and sync services.

**Notation settings** — per-database settings stored inside the notes database (`NotationPrefs`): storage format, encryption, key derivation parameters, sync accounts, allowed file types. Distinct from **app preferences** (`GlobalPrefs`, user defaults).

**Passphrase / master key** — when the database is encrypted, the user's passphrase is stretched with PBKDF2-HMAC-SHA1 into a master key; a verifier key derived from it checks the passphrase; each save uses a fresh session salt for AES-256-CBC.

**Sync service** — a remote copy of the notes kept in step with the notation folder. Today only Simplenote (via Simperium, service key `SN`).

**Notes store** *(planned, #1)* — the deep module that will own the notes database, journal, encryption and atomic writes behind one small interface, so nothing else handles keys, salts or on-disk formats. Sync observes it through one change seam.
