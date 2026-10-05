#!/bin/sh
# Check the archived app: native arm64, no helper executables, only system libraries, no scripting runtimes (#28), a valid
# signature. Then zip it to build/Notational.zip.
set -eu

cd "$(dirname "$0")/.."
app=build/Notational.xcarchive/Products/Applications/Notational.app
for bin in "$app/Contents/MacOS/Notational"; do
	archs=$(lipo -archs "$bin")
	echo "$bin: $archs"
	case " $archs " in *" arm64 "*) ;; *) echo "::error::$bin is not arm64"; exit 1 ;; esac
done
# the app's own binary is the only executable in the bundle; MultiMarkdown is compiled in (ADR 0010)
extra=$(find "$app/Contents" -type f ! -path "$app/Contents/MacOS/Notational" -exec sh -c 'file -b "$1" | grep -q Mach-O' _ {} \; -print)
if [ -n "$extra" ]; then echo "::error::unexpected executables in the app bundle:"; echo "$extra"; exit 1; fi
# only system libraries may be linked; nothing from Homebrew, nix or the build machine
if otool -L "$app/Contents/MacOS/Notational" | tail -n +2 | grep -vE '^\s+(/System/Library/|/usr/lib/)'; then
	echo "::error::unexpected non-system library dependency"; exit 1
fi
# no interpreter scripts shipped, nothing launched through perl/python/ruby
scripts=$(find "$app" \( -name '*.pl' -o -name '*.pm' -o -name '*.py' -o -name '*.pyc' -o -name '*.rb' \) -print)
if [ -n "$scripts" ]; then echo "::error::scripts in the app bundle:"; echo "$scripts"; exit 1; fi
if grep -rnE '/usr/bin/(perl|python|ruby)|Ruby\.framework|env (perl|python|ruby)' --include='*.m' --include='*.h' . ; then
	echo "::error::code launches a scripting runtime"; exit 1
fi
codesign --verify --deep --strict "$app"
rm -f build/Notational.zip
ditto -c -k --keepParent "$app" build/Notational.zip
