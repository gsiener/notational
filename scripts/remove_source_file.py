#!/usr/bin/env python3
"""Remove files from Notation.xcodeproj (file references, build files, group entries).

  scripts/remove_source_file.py Foo.h Foo.m JSON/Bar.m ...

Only edits the project; delete the files themselves with git rm.
"""
import os, re, sys

PBX = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', 'Notation.xcodeproj', 'project.pbxproj')
s = open(PBX).read()
def remove_variant_group(name):
    """Remove a localized resource (e.g. Foo.nib in every .lproj): the variant group, its children and build files."""
    global s
    m = re.search(r'\t\t([0-9A-F]{24}) /\* ' + re.escape(name) + r' \*/ = \{\n\t\t\tisa = PBXVariantGroup;.*?\n\t\t\};\n', s, re.S)
    if not m:
        return False
    group_id, block = m.group(1), m.group(0)
    children = re.findall(r'\t\t\t\t([0-9A-F]{24}) /\*', block)
    s = s.replace(block, '')
    builds = re.findall(r'\t\t([0-9A-F]{24}) /\* [^*]+ \*/ = \{isa = PBXBuildFile; fileRef = ' + group_id, s)
    for ident in builds + children + [group_id]:
        s = '\n'.join(line for line in s.split('\n') if not re.match(r'\s*' + ident + r' ', line))
    return True

if not sys.argv[1:] or any(a.startswith('-') for a in sys.argv[1:]):
    sys.exit(__doc__)
for path in sys.argv[1:]:
    name = os.path.basename(path)
    if remove_variant_group(name):
        print(f'{name}: removed (localized variants)'); continue
    refs = re.findall(r'\t\t([0-9A-F]{24}) /\* ' + re.escape(name) + r' \*/ = \{isa = PBXFileReference', s)
    if not refs:
        print(f'{name}: not in project'); continue
    for ref in refs:
        builds = re.findall(r'\t\t([0-9A-F]{24}) /\* [^*]+ \*/ = \{isa = PBXBuildFile; fileRef = ' + ref, s)
        for ident in builds + [ref]:
            s = '\n'.join(line for line in s.split('\n') if not re.match(r'\s*' + ident + r' ', line))
    print(f'{name}: removed ({len(refs)} reference(s))')
open(PBX, 'w').write(s)
