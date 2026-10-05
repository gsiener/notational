#!/bin/sh
# The built app's memory and leaks after launch on each corpus store (#62): launches Notational in a
# throwaway home folder holding the store, waits for it to settle, then records its footprint, the
# WebKit processes' footprints and what `leaks` finds, as NVPERF lines for scripts/perf-report.py.
# Usage: scripts/perf-app.sh path/to/Notational.app folder-with-Notes-<size>.sqlite
# Opens windows, so run it in CI or a VM, not on your desktop. See docs/research/performance-baseline.md.
set -eu

app=$1
corpus=$2
for size in 2500 10000 25000; do
	home=$(mktemp -d)
	mkdir -p "$home/Library/Application Support/Notational"
	cp "$corpus/Notes-$size.sqlite" "$home/Library/Application Support/Notational/Notes.sqlite"
	CFFIXED_USER_HOME="$home" "$app/Contents/MacOS/Notational" -ShowDockIcon YES -StatusBarItem NO >/dev/null 2>&1 &
	pid=$!
	sleep 30
	# phys_footprint, as Activity Monitor shows it
	fp=$(footprint "$pid" 2>/dev/null | awk -F'Footprint: ' '/Footprint:/ {split($2, a, " "); print a[1], a[2]; exit}')
	echo "NVPERF NotationalApp$size.launch footprint ${fp:-0 unknown}"
	leaks "$pid" > "build/perf-app-leaks-$size.txt" 2>&1 || true
	summary=$(grep -E 'leaks? for [0-9]+ total leaked bytes' "build/perf-app-leaks-$size.txt" | sed -E 's/.*: ([0-9]+) leaks? for ([0-9]+) total.*/\1 \2/')
	echo "NVPERF NotationalApp$size.launch leaks $(echo "$summary" | cut -d' ' -f1) leaks"
	echo "NVPERF NotationalApp$size.launch leakedBytes $(echo "$summary" | cut -d' ' -f2) bytes"
	kill "$pid"
	wait "$pid" 2>/dev/null || true
	rm -rf "$home"
done
