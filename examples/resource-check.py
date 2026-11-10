#!/usr/bin/env python3
"""Read-only resource check on an explicit, already booted disposable simulator."""
import argparse
import json
from pathlib import Path
import subprocess
import time

p = argparse.ArgumentParser(description=__doc__)
p.add_argument('wand', type=Path); p.add_argument('udid'); p.add_argument('--output', type=Path, required=True)
a = p.parse_args()
base = [str(a.wand.resolve()), '--udid', a.udid]
def run(*args):
    return subprocess.check_output(base + list(args), timeout=30, text=True)
run('info')
path = str(Path.home() / '.wand' / ('daemon-' + a.udid + '.sock'))
pids = subprocess.check_output(['/usr/sbin/lsof', '-t', path], text=True).split()
assert len(pids) == 1, pids
pid = pids[0]
run('batch', json.dumps([['ui']] * 20))  # warm up daemon and persistent AX worker
# Isolation moves AX allocations to a child: count both, not only the parent.
children = subprocess.run(['/usr/bin/pgrep', '-P', pid], capture_output=True, text=True, timeout=5).stdout.split()
pids = [pid] + children
def stats():
    rows = subprocess.check_output(['/bin/ps', '-o', 'pid=,rss=,time=', '-p', ','.join(pids)], text=True, timeout=5).splitlines()
    assert len(rows) == len(pids), 'owned process disappeared during resource test'
    rss, cpu = 0, 0
    for row in rows:
        value = row.split()
        parts = [float(part) for part in value[2].split(':')]
        rss += int(value[1])
        cpu += sum(part * 60**index for index, part in enumerate(reversed(parts)))
    return rss, cpu
before, _ = stats()
for _ in range(20): run('batch', json.dumps([['ui']] * 50))
after, cpu_before = stats()
start = time.monotonic(); time.sleep(5)
_, cpu_after = stats()
idle = 100 * (cpu_after - cpu_before) / (time.monotonic() - start)
report = dict(pid=int(pid), measured_pids=[int(p) for p in pids], samples=1000, rss_before_kb=before, rss_after_kb=after,
    growth_mb=(after-before)/1024, idle_cpu_percent=idle)
print(json.dumps(report, indent=2))
a.output.write_text(json.dumps(report, indent=2) + '\n')
assert report['growth_mb'] < 20, 'RSS growth budget failed'
assert idle < 1, 'idle CPU budget failed'
