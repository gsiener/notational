#!/usr/bin/env python3
"""Add Objective-C test files under Tests/ to the NotationTests target.

Usage: scripts/add_test_file.py Tests/FooTests.m [...]
"""
import os, re, secrets, sys

PBX = os.path.join(os.path.dirname(__file__), '..', 'Notation.xcodeproj', 'project.pbxproj')
TARGET_NAME = 'NotationTests'

s = open(PBX).read()
used = set(re.findall(r'\b[0-9A-F]{24}\b', s))

def new_id():
    while True:
        candidate = secrets.token_hex(12).upper()
        if candidate not in used:
            used.add(candidate)
            return candidate

target = re.search(r'\t\t([0-9A-F]{24}) /\* ' + TARGET_NAME + r' \*/ = \{\n\t\t\tisa = PBXNativeTarget;.*?buildPhases = \(\n\t\t\t\t([0-9A-F]{24}) /\* Sources \*/', s, re.S)
sources_phase = target.group(2)
group = re.search(r'\t\t([0-9A-F]{24}) /\* Tests \*/ = \{\n\t\t\tisa = PBXGroup;', s).group(1)

for path in sys.argv[1:]:
    name = os.path.basename(path)
    if re.search(r'/\* ' + re.escape(name) + r' \*/ = \{isa = PBXFileReference', s):
        print(f'{name}: already in project'); continue
    file_ref, build_file = new_id(), new_id()
    s = s.replace('/* End PBXBuildFile section */',
        f'\t\t{build_file} /* {name} in Sources */ = {{isa = PBXBuildFile; fileRef = {file_ref} /* {name} */; }};\n/* End PBXBuildFile section */', 1)
    s = s.replace('/* End PBXFileReference section */',
        f'\t\t{file_ref} /* {name} */ = {{isa = PBXFileReference; lastKnownFileType = sourcecode.c.objc; path = {name}; sourceTree = "<group>"; }};\n/* End PBXFileReference section */', 1)
    s = re.sub(r'(\t\t' + group + r' /\* Tests \*/ = \{\n\t\t\tisa = PBXGroup;\n\t\t\tchildren = \(\n)', r'\g<1>' + f'\t\t\t\t{file_ref} /* {name} */,\n', s, count=1)
    s = re.sub(r'(\t\t' + sources_phase + r' /\* Sources \*/ = \{\n\t\t\tisa = PBXSourcesBuildPhase;\n\t\t\tbuildActionMask = \d+;\n\t\t\tfiles = \(\n)', r'\g<1>' + f'\t\t\t\t{build_file} /* {name} in Sources */,\n', s, count=1)
    print(f'{name}: added')

open(PBX, 'w').write(s)
