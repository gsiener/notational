#!/bin/sh
# Run the unit tests with Address Sanitizer, so memory errors in the C buffers fail the run (#26).
# The performance tests (#62) are slow and meaningless under ASan; scripts/perf.sh runs them.
set -eu

cd "$(dirname "$0")/.."
rm -rf build/TestResults.xcresult
xcodebuild test -project Notation.xcodeproj -scheme NotationTests -enableAddressSanitizer YES \
	-derivedDataPath build/DerivedDataASan -resultBundlePath build/TestResults.xcresult \
	-skip-testing:NotationTests/PerformanceTests2500 -skip-testing:NotationTests/PerformanceTests10000 \
	-skip-testing:NotationTests/PerformanceTests25000 -skip-testing:NotationTests/PerformanceTestsPreview \
	-skip-testing:NotationTests/PerformanceTestsHereNow -skip-testing:NotationTests/PerformanceTestsCorpusExport "$@"
