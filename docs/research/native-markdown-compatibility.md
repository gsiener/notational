# Native Markdown compatibility, issue 41

- Date: 2026-10-03
- Starting baseline: `17d9f92`; current feature branch includes a merge of `origin/master`
- MultiMarkdown source: pinned submodule `b12f292cfc7dde50efd6f2b3cd9d9155f817f313`
- Probe host: macOS 27.0.1, Xcode 27.0; project deployment target: macOS 12.0
- Decision: **keep MultiMarkdown**. Foundation's direct parse and HTML export is not semantically compatible.

## Reproduce the semantic matrix

From the repository root, initialize and build the pinned tool in a checkout-local build folder, then run:

```sh
git submodule update --init --recursive MultiMarkdown-4
mkdir -p build/Issue41MultiMarkdown
rsync -a --exclude .git MultiMarkdown-4/ build/Issue41MultiMarkdown/
env -u CFLAGS -u LDFLAGS make -C build/Issue41MultiMarkdown multimarkdown
python3 docs/research/markdown-compatibility.py --mmd build/Issue41MultiMarkdown/multimarkdown
```

The script builds the Objective-C probe in a temporary directory and feeds each fixture to the live MultiMarkdown executable and Foundation parser. It parses both HTML results with Python's `HTMLParser` and checks elements and attributes rather than byte-for-byte HTML. The TaskPaper case runs `NVTaskPaperMarkdown` once and gives its output to both renderers, matching the app's pre-pass. The runner checks the live output against each semantic requirement and notes any byte difference from the checked-in golden files. None differed in this run.

| Input and requirement | MultiMarkdown live | Foundation direct export |
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
| Dialect: title and author metadata in document head | yes | no |
| Dialect: metadata removed from body | yes | no |
| Dialect: heading anchor | yes | no |
| Dialect: raw `<aside>` element | yes | no |
| Dialect: footnote and backlink | yes | no |

For the dialect input, live MultiMarkdown emitted `<!DOCTYPE html>`, `<title>Dialect sample</title>`, `<meta name="author" content="Test author"/>`, `<h1 id="dialectheading">`, the original `<aside id="raw-note">`, and a footnote target with return link. The corresponding Foundation export retained `Title:` and `Author:` as body paragraphs and produced none of those elements. This is fixture evidence, not evidence of how often people use these features. [Issue 47](https://github.com/gsiener/notational/issues/47) owns the separate product decision about which behaviors remain required; this investigation does not narrow support.

Validation on this host after the master merge: the live semantic runner completed all 17 requirements and found no byte differences in the three existing golden fixtures. Targeted `NVMarkupRendererTests` and `NVTaskPaperMarkdownTests` completed using `build/DerivedDataIssue41`; the `.xcresult` summary reports 28 passed, 0 failed, and 0 skipped. Xcode reported a CoreDevice/CoreSimulator version warning, but the macOS test run passed. The standalone runner is the evidence for live converter output, including TaskPaper, because the XCTest golden tests can return early when their configured converter path is unavailable.

## What a replacement would have to do

The probe parsed the MultiMarkdown fixture and reported 14 presentation-intent runs on this host. That shows Foundation exposes some structure before export. It does not show that its built-in HTML exporter preserves that structure: the resulting HTML has paragraph text such as `ItemQtyeggs12Footnote here.[^1][^1]: The footnote.` in place of table and footnote markup. A serializer over presentation intents would need to create block elements, nested lists, heading anchors, and inline tags; the app would still own MultiMarkdown-specific footnotes, tables, metadata, raw HTML behavior, and typography. TaskPaper adds custom links and done-task markup that the direct exporter drops. This is a substantial dialect renderer, with tests and future OS compatibility work, rather than a small adapter around a system library. No implementation or maintenance reduction is established.

`NVMarkupRenderer` is the shared seam for preview and Save HTML. `PreviewController` renders the note through `htmlForText:` once for Save HTML, then either wraps the fragment with the current custom template/CSS or uses the default standalone page. It bypasses wrapping if the converter emitted a full HTML document. Existing `NVMarkupRendererTests` cover template placeholders, CSS, full-document handling, TaskPaper pre-processing, and the three MultiMarkdown golden files. Any candidate replacement must preserve both Save HTML choices and the actual template DOM/JavaScript behavior; a parser-only result cannot establish that. Preview lifecycle changes belong to issue 40.

## Evidence limits and next gate

The probe and live MultiMarkdown tool were built and run on macOS 27.0.1. The Xcode project targets macOS 12.0, but the current SDK and host are not a macOS 12 runtime. This proves neither Foundation API runtime availability nor behavior parity on macOS 12. A replacement proposal needs the same semantic matrix on a macOS 12 machine or VM, representative notes provided with owner permission, and manual preview/Save HTML checks with the bundled and a custom template. Because the existing direct path fails many requirements, there is no reason to change runtime selection, remove the submodule, or alter build wiring now.
