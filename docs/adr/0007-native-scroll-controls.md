# ADR 0007: Replace custom scrollbar rendering with AppKit controls

- Status: proposed
- Date: 2026-10-02

## Context and proposal

The app carries BWToolKit-derived scroller classes, image assets, and a preference for an older scrollbar appearance.
[ETScrollView](../../ETScrollView.m) already selects ordinary NSScroller when that preference is disabled.
It also opts out of responsive scrolling.

Use NSScrollView and NSScroller with system-selected scroller style and appropriate knob contrast.
Remove custom scroller subclasses and their assets after checking references in every localized nib.
Remove the obsolete appearance preference while retaining scrolling, selection, and split-view behavior.

## Trade-off and acceptance

This reduces drawing code and resource maintenance but changes the scrollbar appearance.
It requires approval of that visible change before implementation.
Test both system scrollbar settings, light/dark backgrounds, trackpad and mouse input, and the collapsed notes list.
Re-evaluate responsive scrolling after removing the custom behavior; do not assume that changing its flag alone is safe.

Apple documents [overlay scrollers](https://developer.apple.com/documentation/appkit/nsscroller/style/overlay) and
[system-selected style](https://developer.apple.com/documentation/appkit/nsscroller/scrollerstyle).
