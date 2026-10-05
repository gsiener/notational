# Performance and memory baseline (#62)

Measured 2026-10-05 on a synthetic corpus of 2,500, 10,000 and 25,000 notes. The real account has about 2,100 live notes, so the 2,500 column is the one that matches today's use.

**Summary.** Search, sorting, preview and sync are fast enough at every size. Four things are worth fixing:

1. **Typing in long notes.** Each keystroke copies the whole note, and with `ShowWordCount` off (the user's setting) it also counts every word in the note.
2. **Building the notes list.** This happens at launch and when a first sync lands, and it does work the list never shows.
3. **Memory.** Every note body is held four times.
4. **Every sync with changes re-sorts the whole list on the main thread.**

One leak was found and fixed (`FastListDataSource`, 77057f7). The ranked proposals are at the end. The first five are now fixed; see [After the fixes](#after-the-fixes).

## Method

- **Corpus.** `Tests/NVPerfCorpus` generates deterministic notes shaped like the real account. On 2026-10-04, aggregate statistics were read from a scratch copy of the store, which was then deleted.
  - Body sizes are log-normal: median about 320 characters, 90th percentile 2.8 KB, 99th about 11 KB. One note in a thousand is 100–300 KB, and every corpus has the same 1 MB note.
  - 45% of notes have non-ASCII text, 15% have links, and some have Markdown, TaskPaper and `@done` lines.
  - 30% of notes have tags. That's more than the real account, so the label paths get exercised.
  - Search terms are planted: a common word, a word in exactly 3 notes, and one in no note.
  - Store files: 12, 39 and 93 MB.
- **Unit performance tests.** `Tests/PerformanceTests.m` uses XCTest `measure` with clock, CPU and memory metrics, plus `NVPERF` lines for one-off figures. They run against `NotationController`, `NVNotesStore`, `NVSyncEngine` with the in-memory Simplenote fake, `NVMarkupRenderer`, a real `WKWebView`, and `NVHereNowSites` with a fake transport.
  - Typing runs the app's own `-[AppController textDidChange:]` through a `LinkingEditor` that is first responder. After each keystroke it lays out and draws the visible part into a bitmap.
  - Notes are opened the way `-displayContentsForNoteAtRow:` does it.
  - Memory figures are live malloc bytes (`malloc_zone_statistics`) measured after the autorelease pool drains, so pages freed by earlier tests don't skew them.
  - `testZLeaks` runs `leaks` on the test process after every other test in the class.
- **The running app.** `UITests/NotationalUIPerformanceTests.m` and `scripts/perf-app.sh` cover launch, scrolling, moving through notes, typing, app memory and leaks. They run only in CI (the `perf` workflow) because they take keyboard focus. Each copies a corpus store into a throwaway home folder. The app then runs local-only, so nothing syncs.
- **The live store is never used.** Tests work on copies of the generated stores in temporary folders.
- **Build.** Tests use the same `ForBuilding` configuration as the shipped app (`-O1`), without Address Sanitizer.
- **Hardware.** Apple M1 Max (10 cores, 64 GB), macOS 27.0.1 (26A434), Xcode 27.0 (27A266a). The test process uses default preferences: preview column on, vertical layout, `ShowWordCount` on.

### Rerunning

```sh
scripts/perf.sh                       # unit performance tests, about 5 minutes; table in build/perf-results.md
scripts/perf.sh -only-testing:NotationTests/PerformanceTests2500/testTypingInHugeNote   # one test
gh workflow run perf.yml -R gsiener/notational   # adds the running-app measurements; results in the run summary
```

`scripts/test.sh` skips the performance classes. Compare runs on the same machine: absolute numbers depend on the hardware.

## Results

Times are the average of 5 iterations (10 for search and sync-apply, 3 for the slowest). Spread was under 10% unless noted.

### Launch: store to a usable notes list

| | 2,500 | 10,000 | 25,000 |
| --- | ---: | ---: | ---: |
| Read every note from SQLite | 17 ms | 52 ms | 122 ms |
| Notes list ready (load, sort, filter, visible previews) | 242 ms | 802 ms | 1,983 ms |
| of which the title-prefix tree for autocomplete | 2.6 ms | 18 ms | 66 ms |
| All list previews at the window's width (queued right after launch) | 8 ms | 34 ms | 103 ms |

A Time Profiler sample at 25,000 notes breaks down "notes list ready" like this:
- `addStrikethroughNearDoneTagsForRange:` 38%. It copies every line of every note into a substring to look for `@done`, even though few notes have one.
- `updateTablePreviewString` 12%. While the controller's title column width is still 0, each note's preview is built from the whole body. See the second proposal.
- Label wiring (`_setLabelString:`, `updateLabelConnections`) 12%.
- The lowercase UTF-8 search buffers 9%.
- SQLite 9%.
- Sorting and the prefix tree, about 5%.

Cold and warm launch of the app itself are in [The running app](#the-running-app).

### Search (`noteContainsUTF8String`)

| | 2,500 | 10,000 | 25,000 |
| --- | ---: | ---: | ---: |
| Typing "meeting agenda", all 14 keystrokes | 2.7 ms | 13 ms | 38 ms |
| Slowest single keystroke | 0.8 ms | 3.2 ms | 8.6 ms |
| First letter `e` from empty (matches nearly all notes) | 0.1 ms | 0.6 ms | 3.4 ms |
| Common word `the` from empty | 0.3 ms | 2.0 ms | 4.5 ms |
| Word in 3 notes / in none (scans every note to the end) | 2.4 ms | 8.2 ms | 20 ms |
| Backspace (can't narrow, rescans every note) | 2.3 ms | 9.7 ms | 27 ms |

Highlighting the search terms in the editor is included in note switching below. Search cost grows linearly and stays well under a frame at today's size. Even at 25,000 notes the worst case, 27 ms, is fine.

### Notes list

| | 2,500 | 10,000 | 25,000 |
| --- | ---: | ---: | ---: |
| Sort by title | 2.3 ms | 14 ms | 47 ms |
| Sort by date modified | 0.5 ms | 2.3 ms | 10 ms |
| Sort by date created | 0.5 ms | 2.6 ms | 7.2 ms |
| Sort by tags | 1.3 ms | 6.0 ms | 19 ms |
| Rebuild with 1,000 here.now Sites interleaved (`NVHereNowMixedList`) | 0.7 ms | 1.2 ms | 2.4 ms |

Scrolling is measured in the running app.

### Note switching

| | |
| --- | ---: |
| 20 notes never shown before, of every size (link detection, text into the editor, highlight, lay out and draw the visible part) | 45–67 ms (2–3 ms each), the same at every corpus size |
| The 1 MB note, first view | 300 ms |

### Typing

20 keystrokes in the middle of a note, each one through `-textDidChange:` and then laid out and drawn:

| Note | Default settings | `ShowWordCount` off (the user's setting) |
| --- | ---: | ---: |
| 3 KB (90th percentile) | 1.8 ms per keystroke | n/a |
| 100 KB (the largest real note is 125 KB) | 2.3 ms | 10.5 ms |
| 1 MB | 14 ms | 87 ms |

Corpus size makes no difference. Two costs dominate:
- **The whole-note copy.** On every keystroke `-[NoteObject setContentString:]` copies the editor's text into the note with `setAttributedString:`. That copy is 85% of the 1 MB case, nearly all of it `NSMutableRLEArray insertObject:range:` moving memory once for each attribute run. So the cost grows faster than the note's length when the note has many links or `@done` lines.
- **The word count.** With `ShowWordCount` off, `updateWordCount:` tokenizes the whole note with ICU on each keystroke. That's 54% of the per-keystroke time in the 1 MB note.

Autosave of the 1 MB note (`synchronizeNoteChanges:` to SQLite) takes 9 ms ±30%, 2.7 seconds after typing stops.

### Preview

| Note size | MultiMarkdown render (background queue) | Reload the page in WKWebView | Update in place |
| --- | ---: | ---: | ---: |
| 1 KB | 0.06 ms | | |
| 10 KB | 0.3 ms | 3.6 ms | 0.4 ms |
| 100 KB | 2.4 ms | 15 ms | 0.7 ms |
| 1 MB | 23 ms | 129 ms | 2.9 ms |

The main-thread part of showing a 100 KB render takes 6.3 ms: the source view's text, the content element, and the page written to a file. The in-place update keeps paying off. MultiMarkdown's allocations with the object pool disabled (ADR 0010) don't matter: 60 previews added 0.1 MB of heap.

### Sync

| | 2,500 | 10,000 | 25,000 |
| --- | ---: | ---: | ---: |
| First sync of the whole account (engine and store, off the main thread) | 113 ms | 392 ms | 1,067 ms |
| Routine cycle: 20 notes changed elsewhere, 20 here (off main) | 6.6 ms ±39% | 8.8 ms ±34% | 12 ms ±18% |
| **Main thread:** the list taking a first sync's notes | 202 ms | 673 ms | 1,652 ms |
| **Main thread:** the list taking a routine cycle's 20 changed notes | 10 ms ±23% | 37 ms ±24% | 129 ms ±13% |

The in-memory server hides network time, which dominates real first syncs. A first sync writes one SQLite transaction per index page of 100 notes, each fsynced (`synchronous = FULL`).

On the main thread, a first sync costs the same as building the list at launch. A routine cycle with any change re-sorts all notes (44% of its time) and rebuilds the whole prefix tree (51%), and touches the 20 changed notes themselves for under 5%.

The fake server used to re-sort every note id for each index page, which made its own cost grow with the square of the account size. It now sorts once per change, so the numbers above measure the engine and the store.

### here.now

| Sites | 100 | 1,000 | 5,000 |
| --- | ---: | ---: | ---: |
| Full refresh (pages answered at once, parsed on the main thread, cache written) | 8 ms | 73 ms | 359 ms |

### Memory

| | 2,500 | 10,000 | 25,000 |
| --- | ---: | ---: | ---: |
| Heap held by the loaded notes list | 37 MB | 119 MB | 282 MB |
| per note | 15.4 KB | 12.5 KB | 11.8 KB |
| per note before the window sets the column width (previews hold whole bodies) | 20.5 KB | 16.4 KB | 15.4 KB |
| Heap growth per note opened (link attributes stay on the note) | 3.6 KB | 15 KB | 5.0 KB |
| Heap growth from 60 previews | 0.1 MB | 0.2 MB | 0.1 MB |
| Heap left behind by a closed notes controller (as after switching accounts) | 0 | 0 | 0 |

A `heap` snapshot of the 10,000-note list breaks down like this:
- Large string buffers: 55 MB, about 2.5 per note.
- Small strings (titles, dates, previews): 41 MB.
- The lowercase search copies (`NoteObject.cContents`, from `BufferUtils`): 18 MB, one per note.

Each body is held four times:
- `NVNoteContent` keeps both the whole content and a separate copy of the body (`string` and `body`).
- The note's attributed `contentString` holds a third.
- `cContents` holds a fourth, in UTF-8.

**WebKit.** The WebContent process takes 11 MB with an empty page and 83 MB showing the 1 MB note. After 30 in-place updates of that note it reached 150 MB, and the test didn't wait long enough to see whether garbage collection takes that back.

**Leaks.** After fixing `FastListDataSource`, `leaks` finds only AppKit and Foundation objects in the test process: `linkd` XPC connection cycles and `NSTextView` scroll blocks, about 20 KB. Nothing from Notational's code is left. The leftovers from the manual retain/release era are mostly `__unsafe_unretained` C arrays of notes (`allNotesBuffer`, `FastListDataSource`), which are safe because `allNotes` owns the notes. Apart from the leak above, none of them showed up in the measurements.

### The running app

From [perf run 37263706966](https://github.com/gsiener/notational/actions/runs/37263706966) on a GitHub `macos-latest` runner: Apple M1 (virtual), macOS 26.6.2, Xcode 26.6. The run's own unit performance numbers came out 10–50% slower than the M1 Max figures above, with more spread.

| | 2,500 | 10,000 | 25,000 |
| --- | ---: | ---: | ---: |
| App footprint 30 s after launch | 115 MB | 239 MB | 521 MB |
| `leaks` on the app after launch | 14 KB, AppKit and Foundation only | 14 KB | 14 KB |
| Launch until the list shows its first row, through XCUITest (first iteration after `sudo purge` / later ones) | 5.8 s / 5.6 s | 8.8 s / 7.4 s | 6.4 s / 6.4 s |
| App peak memory over the UI workload (100 notes shown, then 30 with the preview open) | 135 MB | 263 MB | 563 MB |

These numbers need care:
- **Launch through XCUITest is mostly XCUITest.** It takes about 5.5 s even at 2,500 notes, against 0.3 s in-process. The cold and warm figures barely differ, so the disk cache isn't what limits it. Use the in-process launch figures above to judge the app.
- **App CPU time under XCUITest isn't the app's own work.** It came out large and growing with the list: 21 s of app CPU for 30 arrow keys, and 9.5 to 24 s for scrolling. The likely cause is XCUITest taking accessibility snapshots of the notes table between events, which is work the app does only for XCUITest. That wasn't confirmed, since it would mean driving the UI outside CI. Treat these runs as regression signals between builds of the same workflow, not as latency a user feels.
- **Footprint grows by about 18 KB per note.** That matches the heap per note measured in-process plus AppKit's own share.

The raw log, table and leaks reports are in the run's `perf-results` artifact.

## Proposals

Ranked by user-visible effect, then by cost. Gains are estimates from the profiles above. Proposals 1–5 were accepted and filed as sub-issues of #62. Proposals 6 and 7 were left unfiled: the first is rare, and the second needs investigating before it's a change.

| # | Area | Evidence | Change | Expected gain | Cost |
| --- | --- | --- | --- | --- | --- |
| 1 (#63) | Word count while typing | `updateWordCount:` tokenizes the whole note on each keystroke when `ShowWordCount` is off (the user's setting): 10.5 ms per keystroke at 100 KB, 87 ms at 1 MB | Count after typing pauses (coalesce, as autosave does), or off the main thread | Back to the default-settings numbers: 2.3 ms and 14 ms | Small |
| 2 (#64) | Building the notes list (launch, first sync) | 242 ms / 0.8 s / 2.0 s at launch, and 1.65 s on the main thread for a 25,000-note first sync; `@done` scan 38%, whole-body previews 12% | Check each note for `@done` with one search before scanning lines, or defer it to first display as link detection is. Build no list previews until the controller has a column width. Fix the `size_t` underflow in `attributedSingleLinePreviewFromBodyText:` that also makes a title longer than the column put the whole body in its preview | About half of launch and first-sync time; 25% less memory until the window appears | Small |
| 3 (#65) | Typing in long notes | `setContentString:` copies the whole note on each keystroke: 85% of the 14 ms per keystroke at 1 MB, worse with many links or `@done` lines | Apply only the edited range to the note (from the text storage's edited range and change in length), or let the open note share the editor's text | Keystrokes stop depending on note length: under 2 ms at any size | Medium (undo and remote-merge paths depend on the note's copy) |
| 4 (#66) | Memory per note | 12–15 KB per note; four copies of each body | `NVNoteContent` keeps the title and the leading space and separator lengths instead of the whole content and the body | About a third of the list's heap (about 12 MB today, 90 MB at 25,000) | Medium |
| 5 (#67) | Sync on the main thread | A routine cycle with changes costs 10 / 37 / 129 ms of main thread, nearly all a full re-sort and prefix-tree rebuild | Rebuild the prefix tree only when a title changed; move only the changed notes in the sorted list | Routine sync main-thread cost scales with the changes, not the account | Medium |
| 6 | First view of a very long note | 300 ms for the 1 MB note | Detect links and `@done` lines for the visible part first, the rest in the background | Rare; under 100 ms | Medium |
| 7 | WebContent memory | 83 MB rising to 150 MB over 30 in-place updates of a 1 MB note | Check whether WebKit takes it back; if not, reload the page after a number of in-place updates | Bounded preview memory for long editing sessions | Small to investigate |

No change proposed for search, sorting, the MultiMarkdown preview, the sync engine's own cost, autosave, here.now or the C search buffers. Each is linear and stays under a frame at today's size, or is off the main thread.

## After the fixes

Proposals 1–5 were fixed on 2026-10-05: #63 (22dc1d3), #64 (56af1f9), #65 (6fc471f), #66 (7e3c472) and #67 (ec768bf). The "after" column comes from a full `scripts/perf.sh` run on ec768bf, on the same machine and corpus. Typing times are per keystroke, from 20 keystrokes each laid out and drawn.

| | Before | After |
| --- | ---: | ---: |
| Typing, 100 KB note, `ShowWordCount` off | 10.5 ms | 2.3 ms |
| Typing, 1 MB note, `ShowWordCount` off | 87 ms | 2.6 ms |
| Typing, 1 MB note, default settings | 14 ms | 2.7 ms |
| Typing, 100 KB note / 3 KB note | 2.3 / 1.8 ms | 2.4 / 2.0 ms |
| Notes list ready at launch, 2,500 / 10,000 / 25,000 notes | 242 / 802 / 1,983 ms | 150 / 510 / 1,297 ms |
| First sync applied on the main thread, same sizes | 202 / 673 / 1,652 ms | 104 / 381 / 911 ms |
| Routine sync (20 changes) on the main thread, same sizes | 10 / 37 / 129 ms | 5 / 8 / 12 ms (medians 5 / 6 / 7) |
| Heap held by the notes list, same sizes | 37 / 119 / 282 MB | 29 / 92 / 220 MB |
| Heap per note, 2,500 notes | 15.4 KB | 12.2 KB |

Some proposals fell short of their estimates:
- **#64** saved about 35–45% rather than half, because the synthetic corpus has `@done` lines in many notes. The real account has none, so all of its notes now take the one-search path.
- **#66** saved 22% of the heap rather than a third. Three copies of each body remain: the content `NVNoteContent` needs to give back an untouched note byte for byte, the note's attributed text, and the search buffer.

Search, sorting, preview and opening the 1 MB note are unchanged, as expected. Proposals 6 and 7 remain open ideas.
