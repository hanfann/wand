#!/usr/bin/env python3
"""Required live gate using one owned throwaway; always stops and deletes it."""
import json
import os
from pathlib import Path
import subprocess
import sys
root = Path(__file__).resolve().parents[2]
wand = str(root / '.build/release/wand')
evidence = root / 'live-evidence'
evidence.mkdir(exist_ok=True)
udid = None

def run(args, timeout=60, **kw):
    return subprocess.run(args, check=True, timeout=timeout, **kw)

try:
    catalog = json.loads(subprocess.check_output(['xcrun', 'simctl', 'list', '-j'], timeout=20))
    runtimes = [r for r in catalog['runtimes'] if r.get('isAvailable') and r['identifier'].split('.')[-1].startswith('iOS-')]
    assert runtimes, 'No available iOS runtime; live correctness gate cannot run'
    runtime = max(runtimes, key=lambda r: tuple(int(n) for n in r['version'].split('.')))
    supported = {d['identifier'] for d in runtime.get('supportedDeviceTypes', [])}
    types = [d for d in catalog['devicetypes'] if d['name'].startswith('iPhone') and (not supported or d['identifier'] in supported)]
    assert types, 'No supported iPhone device type'
    udid = subprocess.check_output(['xcrun', 'simctl', 'create', 'Wand CI owned', types[-1]['identifier'], runtime['identifier']], text=True, timeout=30).strip()
    env = dict(os.environ, WAND_UDID=udid, WAND=wand, WAND_OUTCOME_TIMEOUT_SECONDS="20",
               WAND_EVIDENCE_DIR=str(evidence / "portrait"))
    run(['xcrun', 'simctl', 'boot', udid])
    run(['xcrun', 'simctl', 'bootstatus', udid, '-b'], timeout=180)
    run(['bash', str(root / 'examples/native/build.sh')], timeout=180, env=env)
    with (evidence / 'info.txt').open('w') as output:
        run([wand, '--udid', udid, 'info'], stdout=output)
    with (evidence / 'outcomes.txt').open('w') as output:
        run(['bash', str(root / 'examples/native/e2e.sh')], timeout=180, env=env, stdout=output, stderr=subprocess.STDOUT)
    run([wand, '--udid', udid, 'screenshot', str(evidence / 'portrait.png')], timeout=10)
    with (evidence / 'landscape.txt').open('w') as output:
        run(['bash', str(root / 'examples/native/e2e.sh')], timeout=120,
            env=dict(env, WAND_NATIVE_ORIENTATION='landscape', WAND_EVIDENCE_DIR=str(evidence / "landscape")), stdout=output, stderr=subprocess.STDOUT)
finally:
    if udid:
        for args, limit in [([wand, '--udid', udid, 'screenshot', str(evidence / 'final.png')], 10),
                            ([wand, '--udid', udid, 'stop'], 10),
                            (['xcrun', 'simctl', 'shutdown', udid], 30),
                            (['xcrun', 'simctl', 'delete', udid], 30)]:
            try: subprocess.run(args, timeout=limit, capture_output=True)
            except subprocess.TimeoutExpired: print('Cleanup deadline:', args[:3], file=sys.stderr)
