#!/bin/sh
# Build Notational and install it to ~/Applications (or $1), quitting a running copy first.
#
# CI builds are ad-hoc signed, which gives every build a new signature, so macOS asks again
# for the Simplenote token in the keychain after each rebuild (#27). If this Mac has an
# "Apple Development" certificate, re-sign with it: the signature's requirement then stays
# the same from build to build and "Always Allow" sticks. Set SIGN_IDENTITY to choose
# another identity, or SIGN_IDENTITY=- to keep the ad-hoc signature.
set -eu

cd "$(dirname "$0")/.."
DEST="${1:-$HOME/Applications}"
ARCHIVE=build/Notational.xcarchive
APP="$ARCHIVE/Products/Applications/Notational.app"

scripts/build.sh -quiet

if [ -z "${SIGN_IDENTITY+set}" ]; then
	SIGN_IDENTITY=$(security find-identity -v -p codesigning | sed -n 's/.*"\(Apple Development: [^"]*\)".*/\1/p' | head -n 1)
fi
if [ -n "$SIGN_IDENTITY" ] && [ "$SIGN_IDENTITY" != "-" ]; then
	codesign --force --deep --timestamp=none --sign "$SIGN_IDENTITY" "$APP"
	echo "signed with: $SIGN_IDENTITY"
else
	echo "no development certificate: keeping the ad-hoc signature (expect a keychain prompt after each rebuild)"
fi
codesign --verify --deep --strict "$APP"

if pgrep -f "$DEST/Notational.app/Contents/MacOS/Notational" >/dev/null; then
	osascript -e 'tell application "Notational" to quit'
	while pgrep -f "$DEST/Notational.app/Contents/MacOS/Notational" >/dev/null; do sleep 0.5; done
fi
/bin/rm -rf "$DEST/Notational.app"
ditto "$APP" "$DEST/Notational.app"
echo "installed: $DEST/Notational.app"
