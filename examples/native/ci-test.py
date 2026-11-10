#!/usr/bin/env python3
"""Exercise CI process ownership without booting a simulator."""
import os
import signal
from pathlib import Path
import subprocess
import tempfile
import time
from unittest.mock import Mock, patch
import ci

phone = dict(name='iPhone 14', identifier='phone')
duo = dict(name='iPhone Duo', identifier='duo')
general = dict(isAvailable=True, identifier='test.iOS-27-2', version='27.2', supportedDeviceTypes=[phone])
specialized = dict(isAvailable=True, identifier='test.iOS-27-2-iPhone19-4', version='27.2', supportedDeviceTypes=[duo])
for runtimes in ([specialized, general], [general, specialized]):
    assert ci.select_device(dict(runtimes=runtimes, devicetypes=[phone, duo])) == (general, phone)
try:
    ci.select_device(dict(runtimes=[specialized], devicetypes=[phone, duo]))
    raise AssertionError('foldable-only runtime must not silently substitute for the fixture')
except AssertionError as error:
    assert 'No available iOS runtime' in str(error)
print('PASS: runtime/device selection excludes device-specific foldable runtimes')

assert ci.run(['/bin/echo', 'ok'], stdout=subprocess.PIPE).stdout == b'ok\n'
with tempfile.TemporaryFile() as log:
    try:
        ci.run(['/bin/sh', '-c', 'sleep 30 & echo $$ $!; wait'], timeout=1, stdout=log)
        raise AssertionError('deadline did not fire')
    except subprocess.TimeoutExpired:
        pass
    log.seek(0)
    group, child = map(int, log.read().split())
    deadline = time.monotonic() + 2
    while True:
        if not ci.has_live_group(group): break
        assert time.monotonic() < deadline, 'live owned subprocess survived timeout'
        time.sleep(.01)
print('PASS: CI timeout stops the entire owned subprocess group')

for inventory, denied in [('12 Z\n99 S\n', False), ('99 S\n', False), ('12 S\n', True)]:
    with patch.object(ci.os, 'killpg', side_effect=PermissionError('denied')), \
         patch.object(ci.subprocess, 'run', return_value=subprocess.CompletedProcess([], 0, inventory)):
        try:
            ci.signal_group(12, signal.SIGKILL)
            assert not denied, 'live denied group must not be accepted as cleaned up'
        except PermissionError:
            assert denied
with patch.object(ci.os, 'killpg', side_effect=PermissionError('denied')), \
     patch.object(ci.subprocess, 'run', side_effect=subprocess.TimeoutExpired('ps', 2)):
    try:
        ci.signal_group(12, signal.SIGKILL)
        raise AssertionError('unavailable inventory must not establish cleanup')
    except subprocess.TimeoutExpired:
        pass
print('PASS: denied group signals require bounded proof that no live member remains')

commands = []
def fake_run(args, *positional, **kwargs):
    commands.append(args)
    if 'install' in args: raise subprocess.TimeoutExpired(args, 60)
    return subprocess.CompletedProcess(args, 0)
catalog = '{"runtimes":[{"isAvailable":true,"identifier":"test.iOS-27","version":"27"}],"devicetypes":[{"name":"iPhone 14","identifier":"test"}]}'
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

original = subprocess.TimeoutExpired('owned-command', 1)
process = Mock(pid=123, communicate=Mock(side_effect=original), wait=Mock(return_value=0))
with patch.object(ci.subprocess, 'Popen', return_value=process), \
     patch.object(ci, 'signal_group', side_effect=PermissionError('still live')):
    try:
        ci.run(['owned-command'], timeout=1)
        raise AssertionError('original timeout was lost')
    except subprocess.TimeoutExpired as error:
        assert error is original
assert process.wait.call_count == 2
print('PASS: cleanup failure preserves the original timeout and attempts both bounded waits')
