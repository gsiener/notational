#!/bin/sh
# Run the unit tests with Address Sanitizer, so memory errors in the C buffers fail the run (#26).
# Run after build.sh: the Markup renderer's golden-file tests use the bundled multimarkdown.
set -eu

cd "$(dirname "$0")/.."
rm -rf build/TestResults.xcresult
xcodebuild test -project Notation.xcodeproj -scheme NotationTests -enableAddressSanitizer YES \
	-derivedDataPath build/DerivedDataASan -resultBundlePath build/TestResults.xcresult "$@"
