#!/bin/sh
# Run the performance tests (#62) on the synthetic corpus, without Address Sanitizer, and tabulate the
# results. Never touches the live notes store. Takes 15 to 30 minutes; the log goes to build/perf.log
# and the table to build/perf-results.md. Extra arguments go to xcodebuild, for example
#   scripts/perf.sh -only-testing:NotationTests/PerformanceTests2500
# See docs/research/performance-baseline.md.
set -eu

cd "$(dirname "$0")/.."
classes="PerformanceTests2500 PerformanceTests10000 PerformanceTests25000 PerformanceTestsPreview PerformanceTestsHereNow"
only=""
case " $* " in *" -only-testing"*) ;; *) for c in $classes; do only="$only -only-testing:NotationTests/$c"; done ;; esac
rm -rf build/PerfResults.xcresult
status=0
# shellcheck disable=SC2086
xcodebuild test -project Notation.xcodeproj -scheme NotationTests -derivedDataPath build/DerivedDataPerf \
	-resultBundlePath build/PerfResults.xcresult $only "$@" > build/perf.log 2>&1 || status=$?
grep -E "^NVPERF|error:|' failed" build/perf.log || true
scripts/perf-report.py build/perf.log > build/perf-results.md
echo "results: build/perf-results.md"
exit $status
