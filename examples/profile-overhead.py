#!/usr/bin/env python3
"""Interleave profiled/plain warm reads; check per-profile daemon memory retention.

Requires an existing selected daemon. No input, boot, or lifecycle operations.
"""
import argparse
import json
import math
from pathlib import Path
import socket
import statistics
import subprocess
import time

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('wand', type=Path)
parser.add_argument('--udid', required=True)
parser.add_argument('--output', type=Path, required=True)
args = parser.parse_args()
path = str(Path.home() / '.wand' / ('daemon-' + args.udid + '.sock'))
owners = subprocess.check_output(['/usr/sbin/lsof', '-t', path], text=True, timeout=5).split()
assert len(owners) == 1, 'requires one existing selected daemon'
pid = owners[0]


def request():
    with socket.socket(socket.AF_UNIX) as connection:
        connection.settimeout(5)
        connection.connect(path)
        connection.sendall(json.dumps(['profile', '["info"]']).encode() + b'\n')
        with connection.makefile('rb') as reply:
            outer = json.loads(reply.readline(1024 * 1024))
    assert outer['ok'] and json.loads(outer['text'])['ok']


def rss():
    return int(subprocess.check_output(['/bin/ps', '-o', 'rss=', '-p', pid], timeout=5))


base = [str(args.wand.resolve()), '--udid', args.udid]
results = {'plain': [], 'profile': []}
expected = subprocess.check_output(base + ['info'], text=True, timeout=10).rstrip('\n')
for index in range(-1, 30):
    for kind in (['plain', 'profile'] if index % 2 == 0 else ['profile', 'plain']):
        command = ['info'] if kind == 'plain' else ['profile', '["info"]']
        start = time.perf_counter()
        raw = subprocess.check_output(base + command, timeout=10)
        elapsed = (time.perf_counter() - start) * 1000
        actual = raw.decode().rstrip('\n') if kind == 'plain' else json.loads(raw)['result']
        assert actual == expected
        if index >= 0:
            results[kind].append(elapsed)

for _ in range(20):
    request()
before = rss()
for _ in range(1000):
    request()
after = rss()
report = dict(samples_ms=results, summaries={}, profiles=1000,
              daemon_rss_before_kb=before, daemon_rss_after_kb=after,
              daemon_growth_mb=(after - before) / 1024)
for kind, values in results.items():
    report['summaries'][kind] = dict(n=len(values), median_ms=statistics.median(values),
        p95_ms=sorted(values)[math.ceil(.95 * len(values)) - 1], max_ms=max(values))
report['p95_overhead_ms'] = report['summaries']['profile']['p95_ms'] - report['summaries']['plain']['p95_ms']
args.output.write_text(json.dumps(report, indent=2) + '\n')
print(json.dumps({key: value for key, value in report.items() if key != 'samples_ms'}, indent=2))
assert report['p95_overhead_ms'] < 5
assert report['daemon_growth_mb'] < 20
