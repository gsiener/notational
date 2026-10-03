# Native Markdown compatibility, issue 41

- Date: 2026-10-03
- Baseline: `17d9f92` on `gsiener/issue-41-markdown`
- Probe host: macOS 27.0.1, Xcode 27.0; project deployment target: macOS 12.0
- Decision: **keep MultiMarkdown**. Foundation's direct parse and HTML export is not semantically compatible.

## Reproduce the semantic matrix

From the repository root, run:

```sh
python3 docs/research/markdown-compatibility.py
```

The script builds the Objective-C probe in a temporary directory and parses HTML with Python's `HTMLParser`. It checks elements and attributes, rather than byte-for-byte HTML. The MultiMarkdown columns for the three existing fixtures come from the checked-in golden outputs in `Tests/Fixtures/Markup`. Those outputs are reference artifacts, not a fresh run of the binary. The TaskPaper case runs `NVTaskPaperMarkdown` before the Foundation parser, matching the app's pre-pass. The runner asserts that each golden contains its stated semantics, so a broken reference cannot silently produce a passing comparison.

| Input and requirement | MultiMarkdown golden | Foundation direct export |
| --- | --- | --- |
| MultiMarkdown: heading with `id` | yes | no |
| MultiMarkdown: nested lists | yes | no |
| MultiMarkdown: blockquote | yes | no |
| MultiMarkdown: table headers and cells | yes | no |
| MultiMarkdown: emphasis and preformatted code | yes | no |
| MultiMarkdown: footnote target and return link | yes | no |
| MultiMarkdown: ordinary link | yes | yes |
| MultiMarkdown: smart quotes and dash | yes | no |
| Plain Markdown: ordinary link | yes | yes |
| TaskPaper: `nvalt://find/` tag links | yes | no |
| TaskPaper: done-task styling | yes | no |
| TaskPaper: emitted style element | yes | yes |
| Additional dialect input: metadata outside body | reference unavailable | no |
| Additional dialect input: raw `<aside>` element | reference unavailable | no |

The final two rows are **native observations only**. The submodule is uninitialized in this isolated checkout (`git submodule status` begins with `-`), and no built MultiMarkdown binary is present. Pass `--mmd /path/to/multimarkdown` to the runner after building it to obtain live dialect results. A live run should also compare representative real notes with permission from their owner, especially notes that depend on metadata, raw HTML, and template scripts.

Validation on this host: the semantic runner completed with its reference assertions; targeted `NVMarkupRendererTests` and `NVTaskPaperMarkdownTests` completed with `xcodebuild test` using `build/DerivedDataIssue41`. The first sandboxed XCTest attempt could not reach `testmanagerd`; the permitted run outside the sandbox exited successfully. Xcode reported an unrelated CoreDevice/CoreSimulator version warning.

## What a replacement would have to do

The probe parsed the MultiMarkdown fixture and reported 14 presentation-intent runs on this host. That shows Foundation exposes some structure before export. It does not show that its built-in HTML exporter preserves that structure: the resulting HTML has paragraph text such as `ItemQtyeggs12Footnote here.[^1][^1]: The footnote.` in place of table and footnote markup. A serializer over presentation intents would need to create block elements, nested lists, heading anchors, and inline tags; the app would still own MultiMarkdown-specific footnotes, tables, metadata, raw HTML behavior, and typography. TaskPaper adds custom links and done-task markup that the direct exporter drops. This is a substantial dialect renderer, with tests and future OS compatibility work, rather than a small adapter around a system library. No implementation or maintenance reduction is established.

`NVMarkupRenderer` is the shared seam for preview and Save HTML. `PreviewController` renders the note through `htmlForText:` once for Save HTML, then either wraps the fragment with the current custom template/CSS or uses the default standalone page. It bypasses wrapping if the converter emitted a full HTML document. Existing `NVMarkupRendererTests` cover template placeholders, CSS, full-document handling, TaskPaper pre-processing, and the three MultiMarkdown golden files. Any candidate replacement must preserve both Save HTML choices and the actual template DOM/JavaScript behavior; a parser-only result cannot establish that. Preview lifecycle changes belong to issue 40.

## Evidence limits and next gate

The probe was built and run on macOS 27.0.1. The Xcode project targets macOS 12.0, but the current SDK and host are not a macOS 12 runtime. This proves neither API runtime availability nor behavior parity on macOS 12. A replacement proposal needs the same semantic matrix on a macOS 12 machine or VM, live MultiMarkdown results for the additional dialect input, and preview/Save HTML checks with the bundled and a custom template. Because the existing direct path fails many requirements, there is no reason to change runtime selection, remove the submodule, or alter build wiring now.
