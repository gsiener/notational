# Notes-list collapse persistence (issue #34)

**Resolved 2026-10-04.** UI tests now cover both layouts in CI: a dragged divider survives a relaunch, a list collapsed at quit comes back expanded at its earlier size, and expanding restores the size. They passed on the old code and on the simplified code (CI runs 37259333601 and 37259335108). The app opens with no note shown, and the empty view always expands the list, so the restored collapsed state was undone at once. The `NotesListCollapsed` default (removed from defaults once) and `splitViewIsRestoring` are gone. `restoreSplitViewState` expands a list that NSSplitView restores collapsed, at its saved size. Collapsing still requires an open note, for drags, double-clicks and the menu. Note for future UI tests: on the CI runner, preferences outlive a test, so tests must not assume a starting layout or divider position.

## Findings from the current code

`AppController` restores the split view after configuring its layout. `NVSplitView` first converts an old `RBSplitView V centralSplitView` or `RBSplitView H centralSplitView` value only when that orientation has no NSSplitView frames. The converted first frame retains the absolute list dimension and marks a negative legacy dimension as collapsed. The keys are separate for side-by-side and stacked layouts.

`splitViewIsRestoring` allows NSSplitView to collapse the list when `currentNote` is nil. Outside restoration, the delegate permits a drag collapse only while a note is open. Divider double-click also requires an open note unless the list is already collapsed. The menu action toggles the hidden state directly. No drag-collapse policy change is included here.

The app also saves `NotesListCollapsed` separately. During restoration it hides the list if that flag is true and NSSplitView did not restore it as hidden. This is the existing fallback for NSSplitView's reported unreliable hidden-subview restoration. `lastNotesDimension` records the expanded size so menu or double-click expansion can restore it. Removing either copy of state requires a UI relaunch test showing that NSSplitView alone preserves hidden state and expanded size in both layouts.

Switching layout carries the current dimension with a 30-point adjustment, clears the destination layout's NSSplitView autosave frames, and saves the new size. This means the layout keys preserve independent *legacy migration* values until the user switches layout; switching intentionally replaces the destination's saved size. A change to that rule needs a product decision.

## Coverage and limits

`NVSplitViewTests` verifies legacy migration for expanded and collapsed frames in both orientations, including independent collapsed dimensions and refusal to overwrite newer autosave frames. These tests verify conversion and key selection; they cannot prove AppKit's relaunch behavior. No unattended GUI interaction was run in this shared-agent environment.

Manual validation still needed on a dedicated GUI session: in each layout, resize the expanded list, collapse through the menu and divider double-click, relaunch, and expand to check size restoration. Repeat with no selected note, a drag toward collapse, an old RBSplitView defaults profile, and a window resize while collapsed. Record the resulting NSSplitView autosave frames and `NotesListCollapsed` values before considering removal of the fallback.
