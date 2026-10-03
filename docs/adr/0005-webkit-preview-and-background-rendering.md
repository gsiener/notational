# ADR 0005: WebKit preview with background Markdown conversion

- Status: accepted (records the existing implementation)
- Recorded: 2026-10-02
- Evidence: commits `d5da5f6` and `a406ab1`

## Context and decision

Use WKWebView for HTML preview. Preserve custom HTML/CSS templates and their browser behavior.
Convert Markdown on a serial background queue so the external converter does not block editing.
Use request generations to reject obsolete render results.

When the Note and template remain compatible, update the content element in place to preserve the reader's position.
Reload the page when an in-place update cannot preserve behavior, including templates whose scripts ran.

## Consequences

A native attributed-text view is not an equivalent replacement for HTML templates and JavaScript.
The app retains WebKit and coordinates render completion with page navigation.
Existing DOM tests establish some equivalence between patched and reloaded pages.
[Issue 40](https://github.com/gsiener/notational/issues/40) tracks missing lifecycle coverage and possible consolidation of that coordination.

This ADR records the rendering policy, not a commitment to keep every responsibility in PreviewController.
