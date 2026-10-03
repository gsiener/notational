# Issue 44: activation hotkey source reduction

Baseline: `17d9f92` (2026-10-03). Decision: retain PTHotKeys pending behavioral parity and a measured replacement. No shortcut behavior changes were made.

## Current behavior and source footprint

The ten Objective-C files in `PTHotKeys` contain 964 lines (`wc -l PTHotKeys/*.[hm]`). `PTKeyCodes.plist` adds 102 lines, and six localized `PTKeyComboPanel.xib` files plus their strings are separate UI resources. Counting only the 250-line `PTHotKeyCenter.m` overstates the potential saving: the app uses the combo model, localized recorder, key-name data, and callback object as well.

| Component | Lines including header | App use |
| --- | ---: | --- |
| `PTHotKeyCenter` | 284 | Register and unregister, dispatch pressed events, report registration failure |
| `PTHotKey` | 139 | Named activation shortcut, target/action, Carbon registration reference |
| `PTKeyCombo` | 217 | Saved key code and Carbon modifiers, clear state, validity, display name |
| `PTKeyComboPanel` | 226 | Localized sheet, recording, clear/OK/cancel |
| `PTKeyBroadcaster` | 98 | Capture key events in the sheet and convert AppKit modifiers |

`GlobalPrefs` stores `AppActivationKeyCode` and `AppActivationModifiers`, then registers the shortcut on launch. `PrefsWindowController` edits it through `PTKeyComboPanel` and uses the registration result to detect collisions. `AppController` handles the registered event with `toggleNVActivation:`: it hides the visible main window when active, or activates and focuses it otherwise. The center calls `RegisterEventHotKey` on `GetEventDispatcherTarget()` and dispatches a pressed event; released events do nothing.

## Replacement boundary

An app-owned registration object could remove the name-to-object dictionary, ID-to-object dictionary, and several public methods because only one shortcut is registered by the app. That is a **possible reduction within the 423 lines of `PTHotKeyCenter` and `PTHotKey`**, not a 964-line saving. The other 541 lines and localized resources still serve observable behavior. The new object would need to own an `EventHotKeyRef`, install and remove its handler, keep the target/action callback, preserve failure reporting, and handle clearing and re-registration. It would also need to retain the current stored key code/modifier format and existing recorder or replace that UI with demonstrated equivalent behavior.

No implementation was accepted in this audit. A one-shortcut registration rewrite alone would leave most of the bundle in place and create a second registration path. A full replacement has no verified total line count or focus/collision parity yet, so the acceptance condition (less maintained source **and** equivalent behavior) has not been demonstrated. `NSEvent` global monitoring cannot meet the registration semantics or permission constraint.

## Parity and regression plan for a candidate

Automated coverage should verify persisted code/modifier round trips (including clear `-1/-1`), the same key display strings, AppKit-to-Carbon modifier conversion, recorder OK/cancel/clear, and collision failure propagation to preferences. The candidate should expose the Carbon registration result for a targeted integration test without requiring GUI event injection.

Manual checks remain necessary for OS-dispatched behavior: save a shortcut, restart, trigger it with another app focused, trigger it with Notational focused, verify hide/show/focus, attempt a shortcut already owned by another app, and verify the previous shortcut and displayed setting after the collision. Repeat clear and reassignment. These checks must run interactively in an isolated user session; no unattended GUI test was run in this shared environment.

## Integration decision

Keep ADR 0008 proposed. Before replacing PTHotKeys, build the candidate in this branch, measure all new and removed source plus affected app code and resources, run the automated checks above, and record the manual focus/collision results. Merge only if that evidence shows a net reduction with parity.
