# Apple-library dependency audit

- Date: 2026-10-02
- Source revision: `332234e7b44f7d9fce55f7fa83ae1feea0eec2b4`
- Scope: Xcode targets, bundled source, submodules, runtime tools, call sites, fixtures, and archived binary dependencies

The best immediate opportunity is replacing custom scrollers with AppKit controls.
Reducing PTHotKeys is the next candidate, provided a smaller replacement preserves shortcut behavior.
MultiMarkdown has the largest external build footprint, but a direct Foundation replacement fails the existing fixture's output requirements.

**Update 2026-10-04 (#56):** unused SecurityInterface, SystemConfiguration and IOKit links removed (#51); the random-byte helper now uses `SecRandomCopyBytes` (#53); `NSFileManager+DirectoryLocations` replaced by Foundation (#54); Blor import, IDEA and BrokenMD5 deleted (#42). Scrollers (#46) and PTHotKeys (#44) were done earlier. MultiMarkdown (#47) and removing git submodules (#50) remain.

## Inventory

The archived app links only system frameworks and libraries. This does not mean the source tree contains no third-party code.
The MultiMarkdown executable, PTHotKeys, ODBEditor, BWToolKit-derived controls, and legacy crypto sources remain bundled or compiled.
The project targets macOS 12; a replacement must work there unless a separate decision raises that target.

Already migrated:

- Networking and JSON: NSURLSession and NSJSONSerialization in NVSimplenoteHTTPService.
- Cryptographic primitives: CommonCrypto; credential storage: Keychain.
- Link detection: NSDataDetector in AttributedPlainText.
- Storage: system SQLite under ADR 0001.
- Split view: NSSplitView through NVSplitView.
- Preview browser: WKWebView.
- HTML and TaskPaper conversion: native code; Python, Ruby, and Perl conversion dependencies were removed.

Historical acknowledgments are not an accurate dependency inventory. Preserve notices required by source that remains.

## Ranked opportunities

| Priority | Candidate | Replacement | Assessment |
| --- | --- | --- | --- |
| 1 | Custom scrollbar family | NSScrollView and NSScroller | Strong; changes appearance |
| 2 | PTHotKeys framework | Small module using RegisterEventHotKey and AppKit | Worth exploring; source reduction, not Carbon removal |
| 3 | Unused framework links | Remove links after build and runtime checks | Likely cleanup; not a third-party replacement |
| 4 | Random-byte helper | SecRandomCopyBytes, or delete obsolete callers | Small improvement in legacy code |
| 5 | ODBEditor integration | NSWorkspace plus native file-change handling | Conditional; lifecycle behavior differs |
| 6 | MultiMarkdown | Foundation Markdown parsing plus an HTML serializer | Not a compatible direct replacement |
| 7 | IDEA and BrokenMD5 import code | No verified compatible system replacement | Retain unless legacy import is deliberately removed |

## Native scroll controls

[ETScrollView.m](../../ETScrollView.m) already contains an NSScroller path when custom scrollbars are disabled.
The ETTransparentScroller, ETOverlayScroller, and BTTransparentScroller header/implementation pairs total 346 source lines.
Removing them can also remove drawing assets and preference plumbing, after localized nib references are checked.
This figure is an inventory count, not a guaranteed net deletion count.

AppKit supplies [overlay scrollers](https://developer.apple.com/documentation/appkit/nsscroller/style/overlay) and
[style selection](https://developer.apple.com/documentation/appkit/nsscroller/scrollerstyle) based on system preferences and input devices.
ETScrollView explicitly disables responsive scrolling; removing that override needs behavior checks.

Test system scrollbar settings, dark/light backgrounds, scrolling during selection, and the collapsed notes list.
[ADR 0007](../adr/0007-native-scroll-controls.md) records the proposal.

## Smaller hotkey module

[PTHotKeyCenter.m](../../PTHotKeys/PTHotKeyCenter.m) already registers shortcuts with RegisterEventHotKey.
The ten PTHotKeys source/header files total 964 lines. Much of the surrounding code manages objects, preferences, recording, and display.
A small activation-shortcut module can potentially replace that general framework.

Keep collision handling, saved settings, clearing, key names, and recording behavior.
Do not confuse global event monitoring with shortcut registration.
Apple's [NSEvent documentation](https://developer.apple.com/documentation/appkit/nsevent/addglobalmonitorforevents%28matching%3Ahandler%3A%29)
requires accessibility access for keyboard monitoring and states that global monitors cannot modify events.
The installed SDK still declares RegisterEventHotKey in CarbonEvents.h.

This proposal removes bundled source, not Carbon itself. [ADR 0008](../adr/0008-small-native-hotkey-module.md) records the conditions.

## Unused framework links

The project and archived binary still link SecurityInterface, SystemConfiguration, and IOKit.
Source inspection found no active direct calls to their interfaces, and `nm -u` found no matching `SF`, `SC`, or `IO` symbol references.
SecurityInterface names remain in old nib design metadata; that alone does not prove a runtime dependency.

These are removal candidates, not confirmed dead dependencies.
Remove each link separately, rebuild, and exercise launch, account UI, legacy import, and localized nib loading.
Do not remove Security: Keychain and secure text entry still need system security behavior.

## Random bytes

[NSData_transformations.m](../../NSData_transformations.m) opens `/dev/random` and implements a read loop in `randomDataOfLength:`.
Apple's [SecRandomCopyBytes](https://developer.apple.com/documentation/security/secrandomcopybytes%28_%3A_%3A_%3A%29)
can fill the destination buffer directly, with an explicit success/failure result.

The remaining callers are in legacy NotationPrefs and WALController paths.
First establish which write-side compatibility code is still needed. Delete unused code before modernizing it.
If retained, preserve length/error behavior and check the returned status.
This reduces custom code, not an external library dependency.

## External editors

[ODBEditor.m](../../ODBEditor/ODBEditor.m) currently requires ODB-compatible editors and imports temporary-file changes through Apple events.
The five ODBEditor source/header files total 468 lines, excluding ExternalEditorListController and NoteObject integration.

[NSWorkspace](https://developer.apple.com/documentation/appkit/nsworkspace) can open a temporary file in a chosen editor.
[NSFilePresenter](https://developer.apple.com/documentation/foundation/nsfilepresenter/presenteditemdidchange%28%29)
provides change notifications for coordinated file access.
Native directory/file event monitoring may be needed for editors that do not coordinate writes.

This is not a direct replacement for the ODB session protocol.
Test atomic-save replacement, rename, external deletion, concurrent local edits, and temporary-file cleanup.
Opening a file does not provide the same document-close notification as ODB.
Choose a replacement only after deciding that lifecycle behavior; it can otherwise add more code than it removes.

## MultiMarkdown: keep until parity is demonstrated

The submodule build copies and compiles MultiMarkdown, then bundles a separate executable.
[NVMarkupProcessTool](../../NVMarkupRenderer.m) manages its process and pipes.
Eliminating these would reduce build and runtime machinery substantially.

Foundation supports [Markdown parsing](https://developer.apple.com/documentation/foundation/instantiating-attributed-strings-with-markdown-syntax)
and AppKit supports [attributed-text export](https://developer.apple.com/documentation/foundation/nsattributedstring/data%28from%3Adocumentattributes%3A%29).
Those operations do not automatically produce MultiMarkdown-compatible HTML.

### Local probe

Environment: macOS 27.0.1 (26A434), Xcode 27.0 (27A266a).
The probe uses full Markdown syntax and the existing `Tests/Fixtures/Markup/multimarkdown.txt` fixture.

```sh
xcrun clang -Werror -fobjc-arc -framework Cocoa docs/research/apple-markdown-probe.m NVTaskPaperMarkdown.m -o /tmp/notational-markdown-probe
/tmp/notational-markdown-probe Tests/Fixtures/Markup/multimarkdown.txt /tmp/notational-apple-markdown.html
```

The resulting file is `/tmp/notational-apple-markdown.html`.
Parsing succeeded. Direct HTML export produced paragraphs with concatenated block text instead of headings, lists, blockquotes, and tables.
Emphasis and code formatting were lost. Footnote references and definitions remained literal text. Links survived.

This tests the direct parse/export combination, not every possible Foundation-based implementation.
A custom serializer could interpret presentation attributes, but it would become new app-owned code and still need missing dialect behavior.
Check footnotes, metadata, heading anchors, raw HTML, typography, tables, custom templates, and Save HTML before removing MultiMarkdown.
The macOS 12 deployment target also needs its own compatibility run.
The [issue 41 semantic matrix](native-markdown-compatibility.md) reproduces the direct-export gaps across MultiMarkdown, plain Markdown, and TaskPaper fixtures and records the remaining dialect and macOS 12 limits.

[ADR 0004](../adr/0004-shared-markup-rendering.md) records the existing shared-renderer decision and this replacement constraint.

## Legacy IDEA and BrokenMD5

[BlorPasswordRetriever.m](../../BlorPasswordRetriever.m) uses `idea_ossl.c` and `broken_md5.c` to read legacy Blor files.
Those two C files total 615 lines. This is a live import path in AlienNoteImporter, not evidence that the app links external OpenSSL.

The installed CommonCryptor.h algorithm list has no IDEA implementation.
BrokenMD5 is a modified compatibility algorithm; substituting ordinary CommonCrypto MD5 is not justified by its name.
The system CommonCrypto calls already replace ordinary AES, PBKDF2, SHA-1, and MD5 elsewhere.

Keep byte-compatible readers unless Blor support is explicitly retired or moved to a separate migration tool.
That is a product compatibility decision, not a simple library swap.
Keep system zlib for the old archive format unless exact stream compatibility is established for a replacement.

## Validation and limits

This audit inspected source, project linkage, commit history, the archived binary, installed SDK declarations, and Apple documentation.
It ran the standalone Markdown probe. It did not change app code or test proposed replacements in the UI.
Source line counts include declarations and comments and do not estimate replacement size.
The ADR index distinguishes established decisions from proposals awaiting approval.
