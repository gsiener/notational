# Architecture decisions

Accepted records describe agreed behavior or documented decisions already present in the code.
Proposed records require a decision before implementation. Recording a proposal does not authorize a behavior change.

| ADR | Decision | Status |
| --- | --- | --- |
| [0001](0001-simplenote-backed-storage.md) | Simplenote-backed SQLite storage | Accepted |
| [0002](0002-account-transitions.md) | One owner for account transitions | Accepted |
| [0003](0003-native-platform-and-system-libraries.md) | Native AppKit app and system-linked libraries | Accepted, retrospective |
| [0004](0004-shared-markup-rendering.md) | Shared Markdown rendering and HTML export | Accepted, retrospective |
| [0005](0005-webkit-preview-and-background-rendering.md) | WebKit preview and background conversion | Accepted, retrospective |
| [0006](0006-native-import-conversion.md) | Native HTML and TaskPaper conversion | Accepted, retrospective |
| [0007](0007-native-scroll-controls.md) | Replace custom scrollbar rendering | Accepted, implemented |
| [0008](0008-small-native-hotkey-module.md) | Reduce PTHotKeys to app-specific behavior | Accepted |
| [0009](0009-here-now-read-only-sites.md) | Read-only here.now Sites in the Notes list | Accepted |

## Known gaps

ADR 0001 records the intended design. These implementation gaps remain open:

- Remote updates clear undo history. [Issue 39](https://github.com/gsiener/notational/issues/39) tracks undo preservation.
- FrozenNotation, WALController, and related legacy types remain for migration and compatibility tests. Their presence does not restore the old live-storage design.

The [Apple-library dependency audit](../research/apple-library-dependency-audit.md) records candidates, compatibility limits, and validation work.
