#!/usr/bin/env python3
"""Tabulate a scripts/perf.sh log as Markdown (#62).

  scripts/perf-report.py build/perf.log [build/perf-ui.log ...] > build/perf-results.md

Reads XCTest's "measured [...]" lines and the tests' own NVPERF lines, from the unit and the UI
performance tests. Tests run once per corpus size (PerformanceTests2500/10000/25000,
NotationalUIPerformanceTests2500/...) become one row with a column per size.
"""
import re, sys
from collections import OrderedDict

SIZES = ['2500', '10000', '25000']
# XCTest rounds the average to milliseconds; the values carry microseconds, so average those
MEASURED = re.compile(r"Test Case '-\[(\w+) (\w+)\]' measured \[([^\]]+)\] average: [\d.]+, relative standard deviation: ([\d.]+)%, values: \[([^\]]*)\]")
NVPERF = re.compile(r'^NVPERF (\S+) (\S+) ([\d.\-]+) (.*)$')
# shown metrics, with how to scale and label them
METRICS = OrderedDict([
    ('Clock Monotonic Time, s', (1000, 'ms')),
    ('CPU Time, s', (1000, 'CPU ms')),
    ('Memory Peak Physical, kB', (1 / 1024, 'peak MB')),
    ('Memory Physical, kB', (1 / 1024, 'MB')),
    ('Duration (AppLaunch), s', (1000, 'launch ms')),
])


def split_class(cls):
    m = re.match(r'(\w*PerformanceTests)(\d+)$', cls)
    return (m.group(1), m.group(2)) if m else (cls, None)


def fmt(value):
    if value >= 100:
        return '%.0f' % value
    if value >= 10:
        return '%.1f' % value
    return '%.2f' % value


def main(paths):
    measured = OrderedDict()   # (class, test, metric) -> {size: (avg, rsd)}
    extra = OrderedDict()      # (class, test, name, unit) -> {size: value}
    lines = [line for path in paths for line in open(path, errors='replace')]
    for line in lines:
        m = MEASURED.search(line)
        if m:
            cls, size = split_class(m.group(1))
            if m.group(3) not in METRICS:
                continue
            values = [float(v) for v in m.group(5).split(',')]
            measured.setdefault((cls, m.group(2), m.group(3)), {})[size] = (sum(values) / len(values), float(m.group(4)))
            # the perf workflow purges the disk cache before each launch test, so the first launch is cold
            if m.group(2).startswith('testLaunch') and cls.startswith('NotationalUI') and m.group(3) in ('Duration (AppLaunch), s', 'Clock Monotonic Time, s'):
                extra.setdefault((cls, m.group(2), 'first launch (cold)', 'ms'), {})[size] = values[0] * 1000
            continue
        m = NVPERF.match(line.strip())
        if m:
            where, name, value, unit = m.groups()
            cls, _, test = where.partition('.')
            cls, size = split_class(cls)
            extra.setdefault((cls, test or '-', name, unit), {})[size] = float(value)

    sized = sorted({cls for (cls, _, _), by_size in measured.items() if None not in by_size})
    for group in sized:
        print('## %s (average of the iterations; ± relative standard deviation)\n' % group)
        print_sized(group, measured)

    print('\n## Other tests\n')
    print('| Test | Metric | Average |')
    print('| --- | --- | ---: |')
    for (cls, test, metric), by_size in measured.items():
        if None not in by_size:
            continue
        scale, label = METRICS[metric]
        avg, rsd = by_size[None]
        print('| %s.%s | %s | %s ±%.0f%% |' % (cls, test, label, fmt(avg * scale), rsd))

    print('\n## One-off figures\n')
    print('| Test | Figure | Unit | ' + ' | '.join('%s notes' % s for s in SIZES) + ' | Other |')
    print('| --- | --- | --- |' + ' ---: |' * (len(SIZES) + 1))
    for (cls, test, name, unit), by_size in extra.items():
        cells = [fmt(by_size[s]) if s in by_size else '' for s in SIZES]
        other = fmt(by_size[None]) if None in by_size else ''
        print('| %s | %s | %s | %s | %s |' % (test, name, unit, ' | '.join(cells), other))


def print_sized(group, measured):
    print('| Test | Metric | ' + ' | '.join('%s notes' % s for s in SIZES) + ' |')
    print('| --- | --- |' + ' ---: |' * len(SIZES))
    for (cls, test, metric), by_size in measured.items():
        if cls != group:
            continue
        scale, label = METRICS[metric]
        cells = []
        for s in SIZES:
            if s in by_size:
                avg, rsd = by_size[s]
                cells.append('%s ±%.0f%%' % (fmt(avg * scale), rsd))
            else:
                cells.append('')
        print('| %s | %s | %s |' % (test, label, ' | '.join(cells)))
    print()


if __name__ == '__main__':
    main(sys.argv[1:] or ['build/perf.log'])
