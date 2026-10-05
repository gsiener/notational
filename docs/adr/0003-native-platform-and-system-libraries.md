# ADR 0003: Native AppKit app with system-linked libraries

- Status: accepted (records the existing implementation)
- Recorded: 2026-10-02
- Evidence: commits `95e0208`, `29b6e17`, `74ad476`, and `bbcb165`

## Context and decision

Notational remains a native Objective-C/AppKit app for Apple Silicon. The current deployment target is macOS 12.
Use macOS facilities for general-purpose behavior: NSURLSession, NSJSONSerialization, NSDataDetector, CommonCrypto, Keychain, and system SQLite.
Use NSSplitView for the main split view instead of the former RBSplitView dependency.

This choice removes external runtime installation and preserves the existing AppKit editing behavior.
It does not require a SwiftUI rewrite or prohibit all bundled source code.
MultiMarkdown, PTHotKeys, and legacy import code remain separate compatibility decisions. ODBEditor was removed with the external-editor feature (#45).

## Consequences

The build needs only Xcode: no submodules, Homebrew, Nix, or external OpenSSL. MultiMarkdown 6 is vendored source ([ADR 0010](0010-in-process-multimarkdown-6.md)).
[scripts/verify.sh](../../scripts/verify.sh) checks architecture, linked libraries, bundled interpreter scripts, and signing.
That check does not detect statically compiled third-party source. Bundled source must also be audited.

See the [dependency audit](../research/apple-library-dependency-audit.md) for current replacement candidates and limits.
