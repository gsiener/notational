# MultiMarkdown 6 (vendored)

- Upstream: https://github.com/fletcher/MultiMarkdown-6
- Version: 6.8.0, commit `f71254b`
- Contents: the library sources and headers from upstream `src/` (the `src_files`, `public_headers` and `private_headers` lists in its `CMakeLists.txt`, plus `i18n.h`, `parser.h` and `textbundle.h`), without `main.c`, argtable or tests. `version.h` was generated once by CMake from `templates/version.h.in`. Upstream also commits its generated lexer and parser, so building needs no code generator.
- License: `LICENSE` (MIT for MultiMarkdown; uthash is Revised BSD; miniz is MIT). The notices are repeated in `Acknowledgments.txt`.
- Local changes: none. Compiled in the app with `-std=gnu99 -DDISABLE_OBJECT_POOL -w` per file (see ADR 0010). The object pool must stay disabled because the app renders on more than one thread.

To update, copy the same files from a newer upstream commit, regenerate `version.h` with CMake, and run the Markup golden tests. For a wider check, build the upstream `multimarkdown` CLI from the same commit with CMake and pass it to `docs/research/markdown-compatibility.py --mmd`.
