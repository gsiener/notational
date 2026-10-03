#!/usr/bin/env python3
"""Compare HTML semantics from live MultiMarkdown and Foundation.

Run from the repository root:
python3 docs/research/markdown-compatibility.py --mmd build/Issue41MultiMarkdown/multimarkdown
"""

import argparse
from html.parser import HTMLParser
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]
FIXTURES = ROOT / "Tests/Fixtures/Markup"


class Semantics(HTMLParser):
    def __init__(self, html):
        super().__init__(convert_charrefs=True)
        self.tags = []
        self.attrs = []
        self.text = []
        self.paragraphs = []
        self.in_paragraph = False
        self.feed(html)

    def handle_starttag(self, tag, attrs):
        self.tags.append(tag)
        self.attrs.append((tag, dict(attrs)))
        if tag == "p":
            self.in_paragraph = True
            self.paragraphs.append("")

    def handle_endtag(self, tag):
        if tag == "p":
            self.in_paragraph = False

    def handle_data(self, data):
        self.text.append(data)
        if self.in_paragraph:
            self.paragraphs[-1] += data

    def has(self, tag, **attrs):
        return any(t == tag and all(a.get(k) == v for k, v in attrs.items()) for t, a in self.attrs)

    def linked_to(self, fragment):
        return any(t == "a" and fragment in (a.get("href") or "") for t, a in self.attrs)


CHECKS = {
    "heading + anchor": lambda s: s.has("h1", id="groceries"),
    "nested lists": lambda s: "ul" in s.tags and "ol" in s.tags and s.tags.count("li") >= 4,
    "blockquote": lambda s: "blockquote" in s.tags,
    "table cells": lambda s: "table" in s.tags and "th" in s.tags and "td" in s.tags,
    "emphasis + code": lambda s: all(t in s.tags for t in ("em", "strong", "code", "pre")),
    "footnote backlinks": lambda s: s.has("li", id="fn:1") and s.linked_to("#fnref:1"),
    "ordinary link": lambda s: s.linked_to("https://example.com"),
    "smart typography": lambda s: "“quotes”" in "".join(s.text) and "–" in "".join(s.text),
    "TaskPaper tag links": lambda s: s.linked_to("nvalt://find/@today") and s.linked_to("nvalt://find/@done"),
    "TaskPaper done styling": lambda s: "del" in s.tags and s.has("em", **{"class": "tag"}),
    "TaskPaper style": lambda s: "style" in s.tags,
    "metadata in document head": lambda s: s.has("meta", name="author", content="Test author") and "title" in s.tags,
    "metadata removed from body": lambda s: not any("Title:" in p or "Author:" in p for p in s.paragraphs),
    "dialect heading anchor": lambda s: s.has("h1", id="dialectheading"),
    "raw HTML element": lambda s: s.has("aside", id="raw-note"),
    "dialect footnote": lambda s: s.has("li", id="fn:1") and s.linked_to("#fnref:1"),
}

CASES = {
    "multimarkdown": list(CHECKS)[:8],
    "markdown": ["ordinary link"],
    "taskpaper": ["TaskPaper tag links", "TaskPaper done styling", "TaskPaper style"],
    "dialect": ["metadata in document head", "metadata removed from body",
                "dialect heading anchor", "raw HTML element", "dialect footnote"],
}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--mmd", required=True, type=Path, help="built MultiMarkdown executable")
    args = parser.parse_args()
    if not args.mmd.is_file():
        parser.error("--mmd must name a built executable")
    with tempfile.TemporaryDirectory(prefix="notational-markdown-") as scratch:
        probe = Path(scratch) / "probe"
        subprocess.run(["xcrun", "clang", "-Werror", "-fobjc-arc", "-framework", "Cocoa",
                        str(ROOT / "docs/research/apple-markdown-probe.m"),
                        str(ROOT / "NVTaskPaperMarkdown.m"), "-o", str(probe)], check=True)
        print("| Fixture | Semantic requirement | MultiMarkdown | Foundation direct export |")
        print("| --- | --- | --- | --- |")
        for case, checks in CASES.items():
            source = FIXTURES / f"{case}.txt" if case != "dialect" else ROOT / "docs/research/markdown-dialect.txt"
            output = Path(scratch) / f"{case}.html"
            preprocessed = Path(scratch) / f"{case}.md"
            command = [str(probe), str(source), str(output)]
            if case == "taskpaper":
                command.extend(["--taskpaper", str(preprocessed)])
            subprocess.run(command, check=True, capture_output=True, text=True)
            native = Semantics(output.read_text())
            golden = FIXTURES / f"{case}.html"
            rendered = subprocess.run([str(args.mmd.resolve())],
                                      input=(preprocessed if case == "taskpaper" else source).read_text(),
                                      text=True, capture_output=True, check=True).stdout
            reference = Semantics(rendered)
            label = "live"
            if golden.exists() and rendered != golden.read_text():
                print(f"<!-- {case}: live output differs byte-for-byte from checked-in golden -->")
            for name in checks:
                expected = "yes" if CHECKS[name](reference) else "no"
                actual = "yes" if CHECKS[name](native) else "no"
                print(f"| {case} | {name} | {expected} ({label}) | {actual} |")
                if not CHECKS[name](reference):
                    raise AssertionError(f"MultiMarkdown output lacks expected semantic requirement: {case}: {name}")


if __name__ == "__main__":
    main()
