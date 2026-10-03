# ADR 0006: Native HTML and TaskPaper conversion

- Status: accepted (records the existing implementation)
- Recorded: 2026-10-02
- Evidence: commits `8798655`, `cb04649`, and `2269056`

## Context and decision

Use [NVHTMLMarkdown](../../NVHTMLMarkdown.m) for HTML import and [NVTaskPaperMarkdown](../../NVTaskPaperMarkdown.m) for TaskPaper conversion.
HTML import uses Foundation's NSXMLDocument plus app-owned Markdown conversion rules.
TaskPaper conversion uses native code instead of a Ruby script.
Textile support was removed with its Perl dependency.

## Consequences

The app ships no Python, Ruby, or Perl conversion runtime.
It owns conversion rules for links, lists, tables, article extraction, and TaskPaper structure.
An attributed-string HTML importer does not provide those Markdown rules by itself.

Keep the fixture tests when changing these converters. Built-in parsing can reduce infrastructure without replacing domain-specific output behavior.
This decision does not remove MultiMarkdown, which serves the opposite Markdown-to-HTML direction under ADR 0004.
