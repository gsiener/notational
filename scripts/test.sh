#!/bin/sh
# Run the unit tests with Address Sanitizer, so memory errors in the C buffers fail the run (#26).
set -eu

cd "$(dirname "$0")/.."
rm -rf build/TestResults.xcresult
xcodebuild test -project Notation.xcodeproj -scheme NotationTests -enableAddressSanitizer YES \
	-derivedDataPath build/DerivedDataASan -resultBundlePath build/TestResults.xcresult "$@"
