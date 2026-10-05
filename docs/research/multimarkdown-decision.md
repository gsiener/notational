# MultiMarkdown decision evidence (issue 47)

- Date: 2026-10-04
- Source revision: `dd1f639` (master), MultiMarkdown-4 submodule `b12f292`
- Candidates checked out outside the repo: MultiMarkdown-6 `f71254b` (6.8.0), cmark-gfm `27d942c` (0.29.0.gfm.13 + later commits), MultiMarkdown-7 `c46fcaf` (7.0.0-beta.2, context only)
- Host: macOS 27.0.1, Xcode 27.0, CMake 4.4.3, arm64. Project target: macOS 12.0, `ARCHS = arm64`
- Related: [#50](https://github.com/gsiener/notational/issues/50) (zero submodules), [#49](https://github.com/gsiener/notational/issues/49) (Developer ID signing), [#41 report](native-markdown-compatibility.md), [ADR 0004](../adr/0004-shared-markup-rendering.md)

**Question.** Does Notational need MultiMarkdown? If it does, how should it be included without git submodules?

**Short answer.** Yes, it needs a MultiMarkdown-dialect renderer. The rendered output is user-visible in the preview and in saved HTML files. Notes, the bundled CSS and the TaskPaper pre-pass all depend on MultiMarkdown behavior: metadata turns a note into a whole document, headings get `id` anchors, and smart typography, MMD footnotes, tables and definition lists are all in use. Only MultiMarkdown 6 keeps all of these. **The owner's lean holds up under testing.** Recommendation: vendor MultiMarkdown 6.8.0 library sources in-tree, compile them into the app (no helper executable), and build with `DISABLE_OBJECT_POOL`. On this repo's fixtures MMD 6 changes three things. Each can be fixed in the app or accepted. Nothing is lost.

## What the app uses today (from code)

- One call site, with **no arguments**: `NVMarkupRenderer.m:87` runs `Contents/Resources/multimarkdown` with `arguments:nil`, and note text goes in on stdin. Both View ▸ Preview modes ("Markdown" and "(Multi)Markdown") use it (`NVMarkupRenderer.h:12-17`). Preview, Save HTML (`PreviewController.m:437`) and Print all go through `htmlForText:`.
- MMD 4 defaults with no arguments (`MultiMarkdown-4/multimarkdown.c:90-91`) are `EXT_SMART | EXT_NOTES | EXT_OBFUSCATE`. Metadata, heading labels, tables, definition lists, abbreviations, citations, math spans, sup/sub and TOC are on by default. CriticMarkup is off. The stdin path also runs `prepend_mmd_header`, `append_mmd_footer` and **`transclude_source` relative to the process cwd** (`multimarkdown.c:413-447`). So `{{/absolute/path}}` in a note pulls that file into the preview today. That was verified in the scratch copy.
- If a note starts with `Key: value` lines, the output is a complete `<!DOCTYPE html>` document. `NVMarkupRenderer isCompleteDocument:` then skips the template, and Save HTML disables "include template" (`PreviewController.m:438-441`). This also fires by accident: a note that starts `Todo: call the bank` becomes metadata, and that line vanishes from the body. MMD 4 and MMD 6 both do this; verified.
- Templates and CSS: `custom.css:60` / `customclean.css:60` style `.footnote` (superscript), and both style `dt`/`dd` (definition lists). `template.html:29` uses jQuery to smooth-scroll `a[href^=#]`, which serves footnote and heading-anchor links.
- TaskPaper: `NVTaskPaperMarkdown.m:92` emits a one-line `<style>…</style>` and then Markdown with inline HTML (`<em class="tag"><a href="nvalt://find/…">`, `*<del>…</del>*`). The converter must pass raw inline HTML through and treat that `<style>` line as an HTML block.
- Build: pbxproj phase "build multimarkdown" (`project.pbxproj:1521-1540`) rsyncs the submodule and runs `make`, which builds the `greg` parser generator first. It then copies the binary into Resources. `scripts/verify.sh:8` checks that binary's arch. `ci.yml:25` and `release.yml:18` check out submodules recursively, and `README.markdown:15` documents the submodule step. Golden tests read the archived binary (`Tests/NVMarkupRendererTests.m:120-157`).

The fixtures show which features exist and are exercised. They do not show which features people actually use. No user notes were read.

## Feature matrix

Legend: **same** = semantically equivalent HTML; **differs** = supported, but the markup changes; **missing** = not supported. "Run" means verified on this host by running code. "Docs" means only read.

| Feature (evidence it matters) | Class | MMD 4 vendored | MMD 6 | cmark-gfm | Foundation + own serializer |
| --- | --- | --- | --- | --- | --- |
| Paragraphs, emphasis, code, links, lists, blockquote (`markdown`, `multimarkdown` fixtures) | required | same (run) | same (run) | same (run) | parse only; serializer must be written ([#41](native-markdown-compatibility.md)) |
| Heading `id` anchors, e.g. `id="groceries"` (fixture; template scroll JS) | required | same | same, identical ids incl. punctuation/accents (run) | **missing** (run) | missing; app-owned |
| Smart quotes/dashes/ellipsis (fixture) | required | same | same entities (run) | similar, but emits UTF-8 characters, not entities (run) | missing ([#41](native-markdown-compatibility.md)) |
| Footnotes (fixture; `.footnote` CSS) | required | same | **differs**: `<sup>1</sup>` instead of `[1]`; back-link title text and `&#xfe0e;` (run) | differs: `<sup class="footnote-ref">`, `fn-1` ids, `<section>`; no inline `[^text]` footnotes (run) | missing; no presentation intent for footnotes (SDK header) |
| Tables (fixture) | required | same | **differs**: no default `text-align:left` when the separator has no colons; cells keep padding spaces; caption goes *after* the table (run; QuickStart.txt:281) | differs: `align=` attribute, no colgroup/caption (run) | table intents exist (SDK, macOS 12); serializer owed |
| Metadata → complete document with `<title>`/`<meta>` (dialect fixture; Save HTML logic) | required | same | same; `<html>` gains `xmlns`/`lang` (run) | **missing**: rendered as a paragraph (run) | missing |
| Raw HTML blocks/spans (dialect `<aside>`; TaskPaper) | required | same | same, except a one-line `<style>…</style>` gets wrapped in `<p>` (run) | same (run) | inline/block HTML intents exist; serializer owed |
| TaskPaper pre-pass output (fixture) | required | same | **differs** only by that `<p>` wrapper (run) | same apart from whitespace (run) | missing ([#41](native-markdown-compatibility.md)) |
| Definition lists (`dt/dd` CSS) | optional | same | same (run) | missing (run) | missing |
| Fenced code with language class | optional | same | same (run) | same | code block intent |
| Abbreviations | optional | `*[HTML]:` syntax (run) | **differs**: `[>MMD]` syntax; `*[HTML]:` lines show as text (run; QuickStart.txt:67-78) | missing | missing |
| Citations, `{{TOC}}`, math spans, `^sup^`/`~sub~` | optional | supported | supported; citations show `(1)` and get a separate list (run; QuickStart.txt:80-84) | missing (`~` becomes strikethrough) | missing |
| Glossary `[?term]` | unresolved | not supported (text) | new (run) | missing | missing |
| CriticMarkup | unresolved (off today) | off by default (run) | on when the app passes `EXT_CRITIC`; can be left off | missing | missing |
| Transclusion `{{file}}` | unresolved (likely accidental) | **active**, relative to cwd or absolute (run) | off unless the app calls `mmd_transclude_source` (run; `src/main.c:409`, stdin path skips it) | missing | missing |
| `#tag` at line start | unresolved | becomes `<h1>` (run) | stays text; ATX needs a space (run) | stays text | stays text |
| GFM tasklist, `~~strike~~`, bare-URL autolink | not used today | missing | missing; `~~x~~` renders as nested `<sub>` (run) | supported (run) | strikethrough intent only |
| Email obfuscation (default on) | optional | on | on (run) | off | n/a |

Re-running the [#41 semantic matrix script](markdown-compatibility.py) with `--mmd` pointed at the MMD 6 binary: **all 17 requirements pass** for MMD 6. Foundation's direct export still fails 14 of 17 on this host (run).

## Build and distribution cost

| | MMD 4 vendored | MMD 6 vendored, in-process | cmark-gfm vendored | Foundation + serializer |
| --- | --- | --- | --- | --- |
| Removes submodules (#50) | yes, if `parser.c` from greg is checked in | yes; `parser.c` (lemon), `lexer.c`/`scanners.c` (re2c) are already committed upstream, and CMake has no generator step. Built without re2c or lemon installed (run) | yes; `scanners.c` committed upstream | yes |
| Vendored size | 18 lib `.c` + headers, ~11.3k LOC + 16.6k-line generated `parser.c` | full lib: 36 `.c`, 38 `.h`, ~127k LOC, 2.4 MB (68k-line generated `scanners.c`, 7.8k `miniz.c`). HTML-only trim: 19 `.c`, ~88k LOC, 1.3 MB, but it needs a stub file or patch for 21 writer symbols (link test, run) | 34 `.c`, ~25k LOC + 29 headers/`.inc` | 0 vendored; new app code of unknown size |
| Build-time generation | none once `parser.c` is committed | none, except `version.h`, which CMake produces with `configure_file` (`CMakeLists.txt:282`) and which must be committed once | `config.h`, `cmark-gfm_export.h`, `cmark-gfm_version.h` from CMake; commit them | none |
| Compile in the app target with repo settings | target uses `GCC_C_LANGUAGE_STANDARD = gnu89`; with gnu99, 25 warnings (run) | **fails under gnu89** (`for (int i…)` in `writer.c`, `latex.c`); with `-std=gnu99`, 0 errors and 302 warnings, mostly `-Wmissing-prototypes` (147), `-Wsign-compare` (74), `-Wtypedef-redefinition` (71) (run). Use a separate static-library target or per-file `-std=gnu99 -w` | 0 warnings with the same flags under gnu99 (run) | n/a |
| In-process | possible (`libMultiMarkdown.h`), untested | yes: `mmd_string_convert` / `mmd_d_string_convert` give the same bytes as the CLI on all fixtures and 22 probes, ASan clean (run) | yes | yes |
| Threading (ADR 0005 background rendering) | untested | must define `DISABLE_OBJECT_POOL` (`src/libMultiMarkdown.h:14-27`, `src/token.h:59-64`). With it: 8 threads × 200 conversions, TSan clean, outputs identical (run). Without it the probe crashed (SIGSEGV) | documented reentrant (not tested) | yes |
| Helper executable to sign (#49) | removable if linked in-process | **none**: one Mach-O, signed with the app | none | none |
| macOS 12 / arm64 | builds arm64 (run) | built with `-mmacosx-version-min=12.0 -arch arm64` (run); a stripped probe is ~390 KB (MMD 4 CLI is ~590 KB). **Not run on a macOS 12 machine** | same build test (run) | API is macOS 12+ (`NSAttributedString.h:433`, `:657-682`); behavior on 12 not run |
| Speed, ~1 MB note | 0.23 s | 0.02 s CLI, 0.14 s lib without pool (run) | 0.02 s | not measured |

The MMD 6 library also contains epub/ODT/textbundle/OPML/iThoughts/LaTeX writers that the app will never call. Vendoring the full upstream `src/` unmodified makes future updates a plain copy. Trimming saves about 1.1 MB of source but turns every update into a merge. **Recommend: vendor the unmodified full library list** from `CMakeLists.txt:39-75`. Leave out `main.c` and `argtable3.c`, and don't define `USE_CURL`, so `epub.c` compiles without libcurl (`src/epub.c:65-80`).

## Maintenance and license

| | Status | License and notice in Acknowledgments.txt |
| --- | --- | --- |
| MMD 4 | Last commit 2015-11-12. GitHub description: "This project is now deprecated. Please use MultiMarkdown-7 instead!" | MIT or GPL (choose MIT); keep the existing peg-markdown and Gruber notices |
| MMD 6 | Not archived. Releases: 6.6.0 (2020-10), 6.7.0 (2023-06), tag 6.8.0 (2026-07-29, no GitHub release asset). 30 commits since 2023, 39 open issues. One maintainer | MIT (`LICENSE`). Bundled third-party code: uthash (BSD, Troy D. Hanson), miniz (MIT, Geldreich / RAD Game Tools), d_string from Daniel Jalkut / Dan Lowe (MIT), Knuth's public-domain `rng.c`. Copy `LICENSE` plus those headers' notices |
| MMD 7 | Pre-release, 7.0.0-beta.2 (2026-07-29), active (pushed 2026-09-22), MIT. On the three fixtures its HTML is **byte-identical to MMD 6**. It differs from MMD 6 in 7 of 21 probes (tilde fences, list looseness, no email obfuscation) (run) | MIT |
| cmark-gfm | Last tag 0.29.0.gfm.13 (2023-07). 4 commits since 2024, the last on 2026-09-28. Apple's `swiftlang/swift-cmark` `gfm` branch is a more active fork | BSD-2 (John MacFarlane) plus MIT parts (houdini, Vicent Martí; normalization, Karl Dubost) per `COPYING` |
| Foundation | Ships with the OS; Apple controls parser behavior across OS releases | none |

The main maintenance risk for MMD 6 is that upstream has started v7. v6 is likely to get fixes only. Vendoring removes any dependence on upstream availability, and v7's output on these fixtures matches v6. Moving to v7 once it is stable should therefore cost a source swap plus re-checking the goldens, not a second dialect migration. This is an inference from three fixtures and 21 probes.

## Output changes users would see (MMD 4 → MMD 6)

Verified by diffing against `Tests/Fixtures/Markup/*.html`:

1. **Footnote markers.** `<a … class="footnote">[1]</a>` becomes `<a … class="footnote"><sup>1</sup></a>`. Because `.footnote` already uses `vertical-align: super; font-size: .8em`, the number is now superscripted twice: smaller and higher. Fix: add `.footnote sup { vertical-align: baseline; font-size: inherit }` to both bundled CSS files. Users' copies of `custom.css` are left as they are. The back-link title changes from "return to article" to "return to body".
2. **Tables without alignment colons.** MMD 4 adds `style="text-align:left;"` to every `col`/`th`/`td`. MMD 6 adds none and keeps the cell's padding spaces (`<th> Item </th>`). In a browser this looks the same, because left is the default and HTML collapses the spaces. Explicit `:---:` alignment is preserved. Table captions `[Caption]` must come *after* the table in MMD 6.
3. **TaskPaper style line.** `<style>…</style>` becomes `<p><style>…</style></p>`. The style still applies, but an empty paragraph appears. Fix in `NVTaskPaperMarkdown.m:92`: put `<style>`, the rules, and `</style>` on separate lines. A multi-line style block is recognized as raw HTML (run).

Seen only in probes (feature edge cases; frequency unknown):

- `#idea` at the start of a line stays text. MMD 4 turned it into `<h1 id="ideaforlater">`.
- `Para\n- item` with no blank line now starts a list. MMD 4 kept it inside the paragraph. A run of `3.`-style items followed by `*` items becomes two lists, where MMD 4 made one `<ol>`.
- `*[HTML]: …` abbreviation definitions show up as text. `[>MMD]` syntax replaces them.
- `<div markdown="1">` is no longer processed as Markdown.
- `~~text~~` turns into nested `<sub>` instead of literal tildes.
- A backslash at end of line becomes `<br />`.
- `{{/path}}` transclusion stops, unless the app turns it on.
- Complete documents gain `xmlns="http://www.w3.org/1999/xhtml" lang="en"` on `<html>`.

Identical in both (run): heading ids including `Hello, World! & more` → `helloworldmore` and accented ids; smart quotes and dashes, including the dash-ification of dates like `2026–10–05` that both versions share; definition lists; fenced code classes; math spans; sup/sub; TOC; metadata documents.

## Alternatives rejected

- **MMD 4 vendored.** It is the zero-diff path, and its output can be pinned. But it is deprecated upstream (it points to MMD 7). It would need a checked-in 16.6k-line greg-generated parser and gnu99 overrides, and it has never been tested in-process or across threads. It remains the fallback if the owner wants zero output change.
- **cmark-gfm.** Clean, small and warning-free. But it lacks heading ids, metadata/complete documents, definition lists, abbreviations, citations, math and TOC, and it changes footnote markup. Restoring heading ids and metadata would mean app-owned AST walkers, which recreates the dialect-renderer cost that [#41](native-markdown-compatibility.md) warned about. It also adds GFM syntax (tasklists, `~~`) that notes don't use today.
- **Foundation + serializer.** The parse is available on macOS 12. There are no footnote, definition-list or metadata intents, and the direct export fails 14 of 17 requirements (re-run here). The app would own a whole HTML serializer plus all MMD extensions, and Apple can change the parser between OS releases. This has the highest cost and the lowest compatibility.

## Recommendation and migration steps

**Adopt MultiMarkdown 6.8.0, vendored, linked in-process.** It matches the owner's lean, and the run evidence supports it.

1. Copy upstream `src/` library files (the `CMakeLists.txt` `src_files`/headers lists, minus `main.c`/`argtable3.*`) and `LICENSE` to `Vendor/MultiMarkdown-6/`. Commit a pre-generated `version.h`. Record the upstream commit `f71254b` in a `VENDORED.md` or in the ADR.
2. Add an Xcode static-library target, or a group in the app target, compiled with `GCC_C_LANGUAGE_STANDARD = gnu99`, `GCC_PREPROCESSOR_DEFINITIONS = DISABLE_OBJECT_POOL`, warnings inhibited for vendored files, and the static analyzer off for that target. Link it into Notational and NotationTests. **Not yet verified inside Xcode or under `scripts/test.sh` ASan.** The verification here used clang directly with equivalent flags.
3. Add `NVMultiMarkdownTool : NSObject <NVMarkupTool>`, which calls `mmd_string_convert(utf8, EXT_SMART|EXT_NOTES|EXT_OBFUSCATE, FORMAT_HTML, ENGLISH)` and frees the result. Swap it in at `NVMarkupRenderer.m:87`. Keep `NVMarkupProcessTool` only if something else needs it. Whether to add `EXT_CRITIC` or transclusion is a product decision (below).
4. Apply the two fixes: the TaskPaper `<style>` emitted on multiple lines, and the `.footnote sup` CSS rule. Regenerate the three golden files. Make the golden tests use the in-process tool so they no longer skip when no archive exists (`NVMarkupRendererTests.m:145`).
5. Remove the pbxproj build phase and the `multimarkdown` file reference. Remove `.gitmodules` and the `MultiMarkdown-4` gitlink. Drop `submodules: recursive` from both workflows and the submodule line from the README. Drop `Resources/multimarkdown` from `verify.sh`. Replace the MMD 4 notice in `Acknowledgments.txt` with the MMD 6, uthash, miniz and Jalkut/Lowe notices.
6. Write a superseding ADR, or update ADR 0004: in-process MMD 6, no tool process, no submodule. #49's step "sign the helper first" then no longer applies.
7. Before merging, check on a macOS 12 VM if one is available: preview, Save HTML with and without the template, Print. Run the [#41 script](markdown-compatibility.py) against the new build.

## Open product decisions for the owner

**Decided 2026-10-04 ([ADR 0010](../adr/0010-in-process-multimarkdown-6.md)):** adopt MMD 6 in-process; transclusion off; CriticMarkup off; accept the visible differences in item 3 (with the CSS fix). Items 4 and 5 are deferred.

1. **Transclusion.** Today any note containing `{{/some/file}}` shows that local file in the preview and writes it into saved HTML. The note can arrive through Simplenote sync. Recommend leaving it **off** (MMD 6's default in the library). This removes an unexpected local-file read.
2. **CriticMarkup.** It is off today. MMD 6 renders it well. Turning it on is a new feature. Recommend off, to match today's output.
3. **Accept the visible changes**, or patch to match MMD 4: footnote `<sup>`, tables without the left-align style, `#tag` no longer becoming a heading, abbreviation syntax. Recommend accepting all of them except the double superscript, which the CSS change fixes.
4. **Accidental metadata.** MMD 4 and MMD 6 both swallow a first line like `Todo: …` into `<head>`. Keep the current behavior, or later add a preference that passes `EXT_NO_METADATA`? This isn't caused by the migration. Raise it only if users report it.
5. **MMD 7 later.** Plan to re-vendor once 7.0 is stable. Leave it out of scope now.

## Reproduce

Scratch clones lived outside the repo. From a scratch directory:

```sh
git clone https://github.com/fletcher/MultiMarkdown-6.git mmd6
cmake -S mmd6 -B mmd6/build -DCMAKE_BUILD_TYPE=Release -DCMAKE_OSX_ARCHITECTURES=arm64 -DCMAKE_OSX_DEPLOYMENT_TARGET=12.0 && make -C mmd6/build
mmd6/build/multimarkdown < "$REPO/Tests/Fixtures/Markup/multimarkdown.txt" | diff "$REPO/Tests/Fixtures/Markup/multimarkdown.html" -
(cd "$REPO" && python3 docs/research/markdown-compatibility.py --mmd "$OLDPWD/mmd6/build/multimarkdown")
```

For the in-process and thread checks, compile the `src_files` list with `clang -std=gnu99 -DDISABLE_OBJECT_POOL -Isrc -Ibuild` (add `-fsanitize=address` or `-fsanitize=thread`). Link a small driver that calls `mmd_d_string_convert(…, EXT_SMART|EXT_NOTES|EXT_CRITIC, FORMAT_HTML, ENGLISH)`. For TaskPaper, run `NVTaskPaperMarkdown markdownFromTaskPaper:` first, as the app does. cmark-gfm was run as `cmark-gfm --unsafe --smart -e footnotes -e table -e strikethrough -e autolink -e tasklist`.

## Sources

- MultiMarkdown-6: <https://github.com/fletcher/MultiMarkdown-6> — `LICENSE`, `README.md`, `CMakeLists.txt:39-75,194,282`, `src/libMultiMarkdown.h:14-27,119,173,593-611`, `src/token.h:59-64`, `src/main.c:218,409`, `src/epub.c:65-80`, `QuickStart/QuickStart.txt:67-135,276-347`; releases <https://github.com/fletcher/MultiMarkdown-6/releases>
- MultiMarkdown-4: <https://github.com/fletcher/MultiMarkdown-4> (repo description; `LICENSE`; `Makefile:35-54`; `multimarkdown.c:90-91,413-447`)
- MultiMarkdown-7: <https://github.com/fletcher/MultiMarkdown-7> (README "Current Status", tags)
- cmark-gfm: <https://github.com/github/cmark-gfm> (`COPYING`, `src/main.c:228-233`, `--list-extensions`); fork <https://github.com/swiftlang/swift-cmark>
- Apple: macOS SDK `Foundation.framework/Headers/NSAttributedString.h:338-352` (inline intents), `:433` (`NSAttributedStringMarkdownParsingOptions`, macOS 12.0), `:657-682` (`NSPresentationIntentKind`, macOS 12.0); <https://developer.apple.com/documentation/foundation/instantiating-attributed-strings-with-markdown-syntax>
- This repo: `NVMarkupRenderer.m:87,114`, `NVTaskPaperMarkdown.m:92`, `PreviewController.m:403-441`, `custom.css:60`, `template.html:29`, `Notation.xcodeproj/project.pbxproj:1521-1540`, `scripts/verify.sh:8`, `.github/workflows/ci.yml:25`, `release.yml:18`, `README.markdown:15-21`, `Tests/NVMarkupRendererTests.m:120-157`
