# ADR 0010: MultiMarkdown 6, vendored and linked in-process

- Status: accepted, implemented ([#50](https://github.com/gsiener/notational/issues/50))
- Recorded: 2026-10-04
- Evidence: [MultiMarkdown decision report](../research/multimarkdown-decision.md) (issue [#47](https://github.com/gsiener/notational/issues/47))
- Amends: [ADR 0004](0004-shared-markup-rendering.md) (the renderer seam stays; the tool behind it changes)

## Context

Preview, Save HTML and Print render notes through the bundled MultiMarkdown 4 executable. MultiMarkdown 4 is deprecated upstream and comes in as a git submodule with five nested submodules. It is also a separate executable that Developer ID signing (#49) would have to sign on its own. Notes, templates and the TaskPaper pre-pass depend on MultiMarkdown behavior: metadata documents, heading ids, smart typography, footnotes, tables and definition lists.

## Decision

Vendor MultiMarkdown 6.8.0's library sources in-tree, compile them into the app (gnu99, `DISABLE_OBJECT_POOL`, warnings inhibited for vendored files), and call `mmd_string_convert` through an `NVMarkupTool` adapter instead of launching a process. The repo has no git submodules after this change.

Product decisions (owner, 2026-10-04):

- **Transclusion (`{{file}}`) off.** Notes, including notes that arrive by sync, no longer pull local files into the preview or saved HTML.
- **CriticMarkup off**, matching today's output.
- **Accept the visible MMD 6 differences**: footnote markers as `<sup>`, tables without alignment colons losing an explicit left-align, a `#tag` at the start of a line no longer becoming a heading, and abbreviation-syntax changes. The double superscript on footnotes is fixed in CSS, and the TaskPaper `<style>` line is emitted so it stays an HTML block.

## Alternatives and consequences

MultiMarkdown 4 vendored gives zero output change but stays on a deprecated parser. cmark-gfm and Foundation lack heading ids, metadata documents and definition lists, so the app would have to own a dialect renderer ([#41](../research/native-markdown-compatibility.md)).

Implementation: sources in [Vendor/MultiMarkdown-6](../../Vendor/MultiMarkdown-6/VENDORED.md), compiled in both targets with per-file flags `-std=gnu99 -DDISABLE_OBJECT_POOL -w -Xanalyzer -analyzer-disable-all-checks`; `NVMultiMarkdownTool` in [NVMarkupRenderer](../../NVMarkupRenderer.h). `scripts/verify.sh` fails if the bundle contains any Mach-O besides the app binary.

Consequences: no build-time parser generation, no helper executable to sign, and about 127k lines of vendored C (mostly a generated scanner). The upgrade path is to re-vendor when MultiMarkdown 7 is stable; on the current fixtures its output matches MMD 6.
