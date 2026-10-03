# ADR 0004: One renderer for Markdown preview and HTML export

- Status: accepted (records the existing implementation)
- Recorded: 2026-10-02
- Evidence: commits `e695c98`, `cd0af7c`, and `cb04649`

## Context and decision

[NVMarkupRenderer](../../NVMarkupRenderer.h) owns text conversion, TaskPaper preprocessing, template selection, and HTML document assembly.
Preview and Save HTML use this renderer so their output follows one set of rules.
Both Markdown menu modes use the bundled MultiMarkdown executable through NVMarkupTool.
The native TaskPaper converter runs before Markdown conversion when needed.

Keep the tool seam because production and test adapters already use it.
Changing the parser must preserve HTML export, custom templates, and existing Markdown behavior.

## Alternatives and consequences

Foundation can parse Markdown into attributed text. That alone is not a compatible replacement for MultiMarkdown's HTML output.
A local probe found that direct attributed-string HTML export loses block structure and leaves footnote syntax literal.
The [audit](../research/apple-library-dependency-audit.md#multimarkdown-keep-until-parity-is-demonstrated) records the fixture, environment, and reproduction command.

A future replacement needs compatibility tests or an explicit decision to remove features.
The current decision retains a submodule, a build step, a bundled executable, and process invocation.
