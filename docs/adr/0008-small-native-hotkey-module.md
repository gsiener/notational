# ADR 0008: Reduce PTHotKeys to the app's shortcut needs

- Status: implemented in issue #44 branch, pending review
- Date: 2026-10-03

## Decision

Use one app-owned `NVActivationShortcut` to register the activation key with Carbon `RegisterEventHotKey`. Keep `PTKeyCombo`, the localized `PTKeyComboPanel`, `PTKeyBroadcaster`, and key-name resources. Remove `PTHotKeyCenter` and `PTHotKey` from the project and source tree. Do not use a global event monitor or add accessibility permissions.

The owner installs its Carbon event handler before registration. For reassignment it registers the replacement before unregistering the current key, so collision failure leaves the previous registration active. Each registration has a new identifier; queued events from an old registration are ignored after clear or reassignment. Preferences write the saved key code and modifiers, and update the displayed value, only after successful registration. The recorder passes the chosen combination to preferences on OK and leaves it alone on cancel. Clear continues to use `-1/-1`.

## Evidence and limits

The removed registry and object files contain 423 lines. The new owner contains 92 lines. Across production Objective-C files including callers, `git diff --numstat` plus the new owner shows 129 added and 507 removed lines: a net reduction of 378 lines. Project wiring changes are excluded from this source measurement. The retained combo/recorder files and localized resources preserve key naming and UI behavior.

A checkout-local macOS app build and targeted XCTest pass after initializing MultiMarkdown-4 and its `greg` submodule. Five targeted tests exercise real Carbon registration, collision rollback, clear, stale-event rejection, multiple owners, deallocation, preferences persistence, and recorder completion callbacks. Manual verification remains for another app focused, Notational focused, and actual window hide/show/focus behavior in a dedicated interactive session. The draft PR must remain unmerged until that check is completed.

`NSEvent` global monitoring was rejected because it cannot replace registration semantics and may require accessibility access for keyboard monitoring.
