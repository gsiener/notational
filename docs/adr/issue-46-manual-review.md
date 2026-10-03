# Issue 46 native scroller review

## Inspected references

All six localized `Preferences.xib` files (de, en, fr, it, pt-PT, zh) connected the obsolete checkbox to `PrefsWindowController`; those controls and outlets are removed. All six localized `MainMenu.xib` files use `ETScrollView` with ordinary `scroller` elements, not the removed subclasses. The localized `MarkupPreview.xib` files also use ordinary scrollers. The project no longer packages the three custom scroller classes or their directly referenced image resources. Other unreferenced images remain because their ownership is unclear.

## Manual checks still required

Run on a desktop session before landing. For both macOS scrollbar settings (Automatic and Always), verify the notes list, editor, and Markdown source preview in both layouts. Check light and dark note backgrounds for readable knob contrast. Scroll with a mouse wheel and trackpad, drag the thumb, and extend a text or list selection while scrolling. Collapse and expand the list, then relaunch to check the restored width in side by side layout and height in stacked layout. Launch each localization and open Settings to confirm nib loading and the checkbox removal. Review screenshots of the visible appearance change with the product owner. These checks have not been claimed as passed.

Automated validation: all six edited Preferences xibs compile with `ibtool`; the `Notation Develop` app target builds with checkout-local DerivedData; 12 focused `ETScrollViewTests` and `NVSplitViewTests` pass. These tests do not exercise physical input or visual appearance.

Responsive scrolling remains disabled pending selection and hit testing parity. ADR 0007 stays proposed until the visible appearance decision.
