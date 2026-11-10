#!/usr/bin/env python3
"""Exercise CI process ownership without booting a simulator."""
import os
from pathlib import Path
import subprocess
import tempfile
import time
from unittest.mock import patch
import ci

assert ci.run(['/bin/echo', 'ok'], stdout=subprocess.PIPE).stdout == b'ok\n'
with tempfile.TemporaryFile() as log:
    try:
        ci.run(['/bin/sh', '-c', 'sleep 30 & echo $!; wait'], timeout=1, stdout=log)
        raise AssertionError('deadline did not fire')
    except subprocess.TimeoutExpired:
        pass
    log.seek(0)
    child = int(log.read())
    deadline = time.monotonic() + 2
    while True:
        try: os.kill(child, 0)
        except ProcessLookupError: break
        assert time.monotonic() < deadline, 'orphan child survived timeout'
        time.sleep(.01)
print('PASS: CI timeout stops the entire owned subprocess group')

commands = []
def fake_run(args, *positional, **kwargs):
    commands.append(args)
    if 'install' in args: raise subprocess.TimeoutExpired(args, 60)
    return subprocess.CompletedProcess(args, 0)
catalog = '{"runtimes":[{"isAvailable":true,"identifier":"test.iOS-27","version":"27"}],"devicetypes":[{"name":"iPhone 17 Pro","identifier":"test"}]}'
with tempfile.TemporaryDirectory() as directory, patch.object(ci, 'EVIDENCE', Path(directory)), \
     patch.object(ci, 'output', side_effect=[catalog, 'owned-test']), patch.object(ci, 'run', side_effect=fake_run), \
     patch.object(ci.subprocess, 'run', side_effect=subprocess.TimeoutExpired('ps', 5)):
    try:
        ci.main()
        raise AssertionError('install failure was lost')
    except subprocess.TimeoutExpired as error:
        assert 'install' in error.cmd
assert any('shutdown' in args for args in commands)
assert any('delete' in args for args in commands)
print('PASS: setup and diagnostics failure still shut down/delete the owned simulator')
