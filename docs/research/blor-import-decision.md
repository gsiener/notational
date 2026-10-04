# Blor import decision evidence (issue 42)

**Decision (2026-10-04): retired.** Blor import, `BlorPasswordRetriever`, `idea_ossl.c` and `broken_md5.c` are deleted. A `.blor` file passed to the importer is logged as unsupported and imports nothing, and the file is left untouched. The first-launch help notes still use the old `TriedToImportBlor` defaults key, so existing installs don't get them again.

Status: **decision pending**. Retain the current in-app reader until a product choice and an encrypted fixture establish a safe migration route. This report does not authorize removing import support.

## What the checkout establishes

- `AlienNoteImporter notesInFile:` dispatches `.blor` files to `_importBlorNotes:`. That path obtains a passphrase from `BlorPasswordRetriever`, verifies it against the file's first 20 bytes with SHA-1, derives the IDEA key with the modified `BrokenMD5Digest`, then uses `BlorNoteEnumerator` to decrypt and create notes. A keychain lookup or a password dialog supplies the passphrase.
- First-launch import also uses `AlienNoteImporter importBlorOrHelpFilesIfNecessaryIntoNotation:`. `AppController` calls it during setup. Removing only the `.blor` extension branch would leave this path and its preferences and help-note behavior behind.
- The app project compiles `BlorPasswordRetriever.m`, `idea_ossl.c`, and `broken_md5.c` and bundles the password nib. `NSData_transformations.m` is another direct caller of BrokenMD5. The registered `blor` document type is in `Info.plist`.
- `NVLegacyImporter` reads the later Notes & Settings archive and journal. It is a separate migration path and outside this decision.
- The source reader loads Blor into mutable memory, decrypts that buffer, and builds notes. It does not write to the source path. The new invalid-file regression test checks that an original remains unchanged on the rejection path.

## Fixture and conversion check

The tracked checkout has no `.blor` fixture (`find . -iname '*.blor'`). The existing `AlienNoteImporterTests` cover text files but had no encrypted Blor assertion before this investigation. Consequently, no actual encrypted Blor file, correct password, note content, metadata, or complete conversion route was verified. Source inspection supports that the in-app path exists; it does not prove byte-compatible output on current macOS.

A workable route requires a legally shareable encrypted fixture with its passphrase and expected title/body content. Keep the original fixture read-only. Import it using the current app into an isolated test account or local-only store, compare note count and full content with the expected output, and confirm the original file's digest is unchanged. Repeat against any proposed converter, including wrong-password and truncated-file cases. Exercise the first-launch path separately because it also changes encryption preferences and help-note behavior. Record the supported macOS version and encoding used for the passphrase.

## Options for product decision

| Option | Effect | Required evidence and work |
| --- | --- | --- |
| Retain in app | Preserves direct and first-launch Blor import; keeps IDEA, BrokenMD5, and password UI bundled. | Add a real encrypted fixture regression and verify import on supported macOS releases. Audit malformed-file handling before accepting untrusted Blor input. |
| Isolate converter | Keeps a migration route while removing Blor code from normal app builds. | Prove fixture parity and safe, documented handoff into a supported import format. Decide how passwords are entered, how metadata is mapped, and where users obtain the converter. Keep originals. Only then remove the app's Blor entry points and resources. |
| Retire | Shrinks the app and ends Blor compatibility. | Explicit product approval, a verified conversion route for existing users, and clear unsupported-file guidance. Check the first-launch hook, preferences, document type, password nib, crypto callers, and license notices. Do not affect ordinary files, HTML, CSV/TSV, Stickies, or `NVLegacyImporter`. |

**Recommendation:** retain for now. Isolation is a plausible later choice, but it cannot meet parity or provide a verified conversion route without an encrypted fixture. Retirement is premature for the same reason. No legacy reader or encryption code was removed in this issue.

## Remaining manual checks

With an actual encrypted fixture: import through Note → Import, verify note count and contents, try wrong and correct passwords, verify the source digest, and test first-launch import in a fresh profile. The targeted automated test only checks malformed-file rejection and preservation; it cannot establish encrypted-file compatibility.
