#!/usr/bin/env python3
"""Register source files and system libraries with Notation.xcodeproj.

  scripts/add_source_file.py Tests/FooTests.m        # test-only file -> NotationTests, "Tests" group
  scripts/add_source_file.py --app Foo.h Foo.m       # app file -> Notation + NotationTests, "Classes" group
  scripts/add_source_file.py --lib libsqlite3.tbd    # SDK library linked into both targets

App sources are compiled into the test bundle too, because NotationTests has no host app.
Headers are added to the group only.
"""
import os, re, secrets, sys

PBX = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', 'Notation.xcodeproj', 'project.pbxproj')
s = open(PBX).read()
used = set(re.findall(r'\b[0-9A-F]{24}\b', s))

def new_id():
    while True:
        candidate = secrets.token_hex(12).upper()
        if candidate not in used:
            used.add(candidate)
            return candidate

def target_phase(target, phase):
    block = re.search(r'\t\t[0-9A-F]{24} /\* ' + target + r' \*/ = \{\n\t\t\tisa = PBXNativeTarget;.*?\n\t\t\};', s, re.S).group(0)
    return re.search(r'([0-9A-F]{24}) /\* ' + phase + r' \*/', block.split('buildPhases = (')[1]).group(1)

def group_id(name):
    return re.search(r'\t\t([0-9A-F]{24}) /\* ' + re.escape(name) + r' \*/ = \{\n\t\t\tisa = PBXGroup;', s).group(1)

def add_to_list(owner, line):
    global s
    s = re.sub(r'(\t\t' + owner + r' /\* [^*]+ \*/ = \{\n\t\t\tisa = \w+;\n(?:\t\t\t\w+ = \d+;\n)?\t\t\t(?:files|children) = \(\n)',
               lambda m: m.group(1) + line, s, count=1)

def insert_section(section, text):
    global s
    s = s.replace(f'/* End {section} section */', text + f'/* End {section} section */', 1)

args = sys.argv[1:]
mode = 'test'
if args and args[0] in ('--app', '--lib'):
    mode, args = args[0][2:], args[1:]
targets = ['Notation', 'NotationTests'] if mode in ('app', 'lib') else ['NotationTests']

for path in args:
    name = os.path.basename(path)
    if re.search(r'/\* ' + re.escape(name) + r' \*/ = \{isa = PBXFileReference', s):
        print(f'{name}: already in project'); continue
    ref = new_id()
    if mode == 'lib':
        insert_section('PBXFileReference', f'\t\t{ref} /* {name} */ = {{isa = PBXFileReference; lastKnownFileType = "sourcecode.text-based-dylib-definition"; name = {name}; path = usr/lib/{name}; sourceTree = SDKROOT; }};\n')
        add_to_list(group_id('Frameworks'), f'\t\t\t\t{ref} /* {name} */,\n')
        phase_name, suffix = 'Frameworks', 'Frameworks'
    else:
        kind = 'sourcecode.c.h' if name.endswith('.h') else ('sourcecode.c.c' if name.endswith('.c') else 'sourcecode.c.objc')
        insert_section('PBXFileReference', f'\t\t{ref} /* {name} */ = {{isa = PBXFileReference; lastKnownFileType = {kind}; path = {name}; sourceTree = "<group>"; }};\n')
        add_to_list(group_id('Classes' if mode == 'app' else 'Tests'), f'\t\t\t\t{ref} /* {name} */,\n')
        phase_name, suffix = 'Sources', 'Sources'
        if name.endswith('.h'):
            print(f'{name}: added (header)'); continue
    for target in targets:
        bf = new_id()
        insert_section('PBXBuildFile', f'\t\t{bf} /* {name} in {suffix} */ = {{isa = PBXBuildFile; fileRef = {ref} /* {name} */; }};\n')
        add_to_list(target_phase(target, phase_name), f'\t\t\t\t{bf} /* {name} in {suffix} */,\n')
    print(f'{name}: added to {", ".join(targets)}')

open(PBX, 'w').write(s)
