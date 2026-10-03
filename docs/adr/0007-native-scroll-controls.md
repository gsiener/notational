# ADR 0007: Use native AppKit scroll controls

- Status: accepted, implemented
- Date: 2026-10-02
- Accepted: 2026-10-03

## Decision

Use AppKit `NSScrollView` and `NSScroller` for the notes list and editor. Let the system choose the scroller style from the user's macOS setting. Set a light or dark knob for the app's custom note background; when the color cannot be converted to RGB, use AppKit's default knob style.

Remove the obsolete nvALT scrollbar preference and the three custom scroller classes after checking localized nib references. Retain historical license attribution in `Acknowledgments.txt`. Keep responsive scrolling disabled until selection and editor hit testing have demonstrated parity. Preserve the existing split-view sizing and collapse state behavior; issue #34 owns its redesign.

## Evidence and follow-up

The implementation and localized nib audit are recorded in [the issue 46 review](issue-46-manual-review.md). The app builds, the edited localized Preferences nibs compile, and focused scroll and split-view tests pass. Physical mouse and trackpad input, selection while scrolling, all system scrollbar settings, restored dimensions in both layouts, and appearance remain manual checks; the review does not claim they passed.

The accepted product decision is to proceed with native controls despite the visible appearance change. Manual findings can lead to follow-up fixes without restoring the obsolete rendering path.

Apple documents [overlay scrollers](https://developer.apple.com/documentation/appkit/nsscroller/style/overlay) and [system-selected style](https://developer.apple.com/documentation/appkit/nsscroller/scrollerstyle).
