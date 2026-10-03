# ADR 0008: Reduce PTHotKeys to the app's shortcut needs

- Status: proposed
- Date: 2026-10-02

## Context and proposal

[PTHotKeys](../../PTHotKeys) contains ten Objective-C files, totaling 964 lines including comments and declarations.
Its registration code already calls Apple's RegisterEventHotKey.
The opportunity is to remove general-purpose wrapper code, not replace an external keyboard runtime.

Replace the bundled framework with a small app-owned module for activation shortcut registration and editing.
Keep Apple's global-hotkey registration and a native AppKit recording control.
Preserve stored shortcuts, display names, collision reporting, clearing, and focus behavior.

## Rejected shortcut

Do not substitute NSEvent global monitoring without a separate behavior decision.
Apple says keyboard monitoring requires accessibility access, and global monitors cannot modify events.
Monitoring is not the same operation as registering a shortcut.

This proposal removes bundled source, not the Carbon framework dependency.
Before implementation, compare the replacement's size and behavior with the current code and localized shortcut panel.
If equivalent behavior needs comparable code, retain PTHotKeys rather than create another general-purpose framework.

References: [current registration](../../PTHotKeys/PTHotKeyCenter.m) and
[Apple event-monitor documentation](https://developer.apple.com/documentation/appkit/nsevent/addglobalmonitorforevents%28matching%3Ahandler%3A%29).
