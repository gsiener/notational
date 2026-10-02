#!/bin/sh
# Check the archived app: native arm64, only system libraries, no scripting runtimes (#28), a valid
# signature. Then zip it to build/Notational.zip.
set -eu

cd "$(dirname "$0")/.."
app=build/Notational.xcarchive/Products/Applications/Notational.app
for bin in "$app/Contents/MacOS/Notational" "$app/Contents/Resources/multimarkdown"; do
	archs=$(lipo -archs "$bin")
	echo "$bin: $archs"
	case " $archs " in *" arm64 "*) ;; *) echo "::error::$bin is not arm64"; exit 1 ;; esac
done
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
