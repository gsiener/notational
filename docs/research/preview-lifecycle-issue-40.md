# Preview lifecycle investigation (#40)

Issue #40 described a testability gap, with no reproduced preview failure. This checkout kept the existing Markup renderer and WebKit page path. It did not split `PreviewController`: the controller already owns render generation, page identity, and reload decisions, so moving those fields would not reduce coordination for its callers.

## Findings and changes

The controller had two observable gaps. Entering sticky mode did not invalidate an in-flight render. Hiding the window invalidated an in-flight render only after a later text-change notification; a queued debounce could still start after hiding. Hiding, closing, and entering sticky mode now cancel queued preview calls and advance the generation. The render completion also checks visibility and sticky state before showing HTML.

A small `markupRenderer` method lets lifecycle tests use a controlled renderer. The production path still returns `NVMarkupRenderer defaultRenderer` for preview, patching, and reloads.
The same visibility and sticky checks now guard delayed JavaScript patch fallback and scroll-read callbacks before they start a reload.

## Evidence

- `PreviewLifecycleTests` holds background conversion, switches Notes, then releases both conversions. Only the newer Note's HTML, identity, and title reach `showHTML:`.
- The lifecycle tests hide and reopen the preview while conversion is pending, enter and leave sticky mode during conversion, and hide while a debounced update is pending. Each accepted render is observed with an expectation; teardown gives workers a bounded release and waits for them to exit.
- Controller-level tests check that Note identity, title, and template key agree before an in-place patch, and that delayed patch and scroll callbacks cannot start reloads after the page becomes hidden or sticky.
- `PreviewPageTests` still checks DOM equivalence, script-driven reload fallback, and script failure. The new WebKit fixture verifies that an in-place content update preserves the scroll position of a template-owned scroll container when the preceding content keeps its geometry.
- `NVMarkupRendererTests` covers template selection, template-key changes, title interpolation, and content-element eligibility. The controller's existing conditions require Note identity, title, content-element ID, and template key to agree before patching.

Validation: 35 focused `PreviewLifecycleTests`, `PreviewPageTests`, and `NVMarkupRendererTests` passed on macOS 27.0.1 with checkout-local `build/DerivedDataIssue40` after merging master. The first sandboxed `xcodebuild test` reached compilation but could not connect to `testmanagerd`; the approved unsandboxed run passed.

## Limits and integration checks

The controlled lifecycle tests intercept page loads and JavaScript completion; they do not exercise the full controller through a live window, WebKit navigation callback, and file-based page reload. Before integration, manually switch Notes rapidly while preview is open; hide and reopen during a slow render; enter and leave sticky mode; edit a Note's title and custom template; check that the displayed page and window title agree; and verify scroll restoration after a script-triggered reload. These checks should use this branch's app build and should not run unattended alongside other agents' GUI work.
