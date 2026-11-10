#!/usr/bin/env python3
"""Repeatable release-binary benchmarks. No simulator is booted or modified.

python3 examples/performance.py PATH_TO_WAND --output measurements.json
Optional --udid measures reads on an already booted disposable simulator.
"""
import argparse
import json
import math
from pathlib import Path
import socket
import statistics
import subprocess
import tempfile
import threading
import time
import uuid

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('wand', type=Path)
parser.add_argument('--output', type=Path, required=True)
parser.add_argument('--udid')
parser.add_argument('--samples', type=int, default=30)
args = parser.parse_args()
if args.samples < 5:
    parser.error("--samples must be at least 5 for useful percentiles")
wand = str(args.wand.resolve())
measurements = {}

def measure(name, command, count=None, stdin=None):
    times = []
    for _ in range(count or args.samples):
        start = time.perf_counter()
        result = subprocess.run(command, input=stdin, capture_output=True, timeout=30)
        elapsed = (time.perf_counter() - start) * 1000
        if result.returncode:
            raise RuntimeError((name, result.stderr.decode(errors='replace')))
        times.append(elapsed)
    ordered = sorted(times)
    measurements[name] = dict(n=len(times), median_ms=statistics.median(times),
        p95_ms=ordered[math.ceil(.95 * len(times)) - 1], max_ms=max(times),
        output_bytes=len(result.stdout), samples_ms=times)
    print(name, json.dumps({k: round(v, 3) if isinstance(v, float) else v
        for k, v in measurements[name].items() if k != 'samples_ms'}), flush=True)

# Fixed fake daemon isolates CLI/socket/JSON overhead from CoreSimulator.
udid = 'perf-' + uuid.uuid4().hex
directory = Path.home() / '.wand'
directory.mkdir(mode=0o700, exist_ok=True)
path = directory / ('daemon-' + udid + '.sock')
server = socket.socket(socket.AF_UNIX)
server.bind(str(path)); server.listen(16); server.settimeout(.1)
stopping = threading.Event()

def serve():
    while not stopping.is_set():
        try:
            connection, _ = server.accept()
        except socket.timeout:
            continue
        with connection:
            request = bytearray()
            while not request.endswith(b'\n'):
                chunk = connection.recv(16384)
                if not chunk:
                    break
                request.extend(chunk)
            command = json.loads(request)
            text = 'x' * 131072 if command[0] == 'large' else 'pong'
            connection.sendall(json.dumps(dict(ok=True, text=text)).encode() + b'\n')

thread = threading.Thread(target=serve)
thread.start()
try:
    measure('cli_small', [wand, '--udid', udid, 'ping'])
    measure('cli_128k', [wand, '--udid', udid, 'large'])
    requests = b''.join(json.dumps(dict(jsonrpc='2.0', id=i, method='tools/list')).encode() + b'\n' for i in range(100))
    measure('mcp_100_catalogs', [wand, 'mcp', '--compact'], count=10, stdin=requests)
finally:
    stopping.set(); thread.join(); server.close(); path.unlink(missing_ok=True)

if args.udid:
    base = [wand, '--udid', args.udid]
    subprocess.run(base + ['info'], check=True, capture_output=True, timeout=30)
    for name, command in [('warm_info', ['info']), ('warm_ui', ['ui']),
                          ('batch_20_ping', ['batch', json.dumps([['ping']] * 20)])]:
        measure(name, base + command)
    with tempfile.TemporaryDirectory(prefix='wand-perf-') as scratch:
        measure('screenshot', base + ['screenshot', scratch + '/frame.png'])
    measure('ocr_fast_and_cache', base + ['see'], count=10)

args.output.parent.mkdir(parents=True, exist_ok=True)
args.output.write_text(json.dumps(measurements, indent=2) + '\n')
