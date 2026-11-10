#!/usr/bin/env python3
"""Required live gate: build before boot, own one throwaway, always clean up."""
import json
import os
from pathlib import Path
import shlex
import signal
import subprocess
import sys
import time

ROOT = Path(__file__).resolve().parents[2]
WAND = str(ROOT / '.build/release/wand')
EVIDENCE = ROOT / 'live-evidence'


def run(args, timeout=60, **kwargs):
    print(time.strftime('%H:%M:%S'), shlex.join(map(str, args)), flush=True)
    process = subprocess.Popen(args, start_new_session=True, **kwargs)
    try:
        stdout, stderr = process.communicate(timeout=timeout)
    except BaseException:
        # Killing a shell alone leaves its compiler/test children consuming RAM.
        # The new session belongs exclusively to this invocation.
        try:
            os.killpg(process.pid, signal.SIGTERM)
            process.wait(timeout=1)
        except ProcessLookupError:
            pass
        except subprocess.TimeoutExpired:
            pass
        finally:
            try:
                os.killpg(process.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            process.wait(timeout=2)
        raise
    if process.returncode:
        raise subprocess.CalledProcessError(process.returncode, args, stdout, stderr)
    return subprocess.CompletedProcess(args, process.returncode, stdout, stderr)


def output(args, timeout=60):
    return run(args, timeout, stdout=subprocess.PIPE, text=True).stdout


def main():
    EVIDENCE.mkdir(exist_ok=True)
    udid = None
    boot_requested = False
    try:
        # Avoid the compiler's memory peak overlapping first-boot migrations.
        with (EVIDENCE / 'build.txt').open('w') as log:
            run(['bash', str(ROOT / 'examples/native/build.sh')], timeout=180,
                env=dict(os.environ, WAND_BUILD_ONLY='1', WAND_UDID='build-only'),
                stdout=log, stderr=subprocess.STDOUT)
        catalog = json.loads(output(['xcrun', 'simctl', 'list', '-j'], timeout=120))
        runtimes = [r for r in catalog['runtimes'] if r.get('isAvailable') and r['identifier'].split('.')[-1].startswith('iOS-')]
        assert runtimes, 'No available iOS runtime; live correctness gate cannot run'
        runtime = max(runtimes, key=lambda r: tuple(int(n) for n in r['version'].split('.')))
        supported = {d['identifier'] for d in runtime.get('supportedDeviceTypes', [])}
        types = [d for d in catalog['devicetypes'] if d['name'].startswith('iPhone') and (not supported or d['identifier'] in supported)]
        assert types, 'No supported iPhone device type'
        preferred = next((d for d in types if d['name'] == 'iPhone 17 Pro'), types[-1])
        udid = output(['xcrun', 'simctl', 'create', 'Wand CI owned', preferred['identifier'], runtime['identifier']], timeout=30).strip()
        (EVIDENCE / 'device.json').write_text(json.dumps(dict(udid=udid, device=preferred['name'], runtime=runtime['version']), indent=2))
        env = dict(os.environ, WAND_UDID=udid, WAND=WAND, WAND_OUTCOME_TIMEOUT_SECONDS='20',
                   WAND_EVIDENCE_DIR=str(EVIDENCE / 'portrait'))
        boot_requested = True  # A timed-out boot may still apply.
        run(['xcrun', 'simctl', 'boot', udid])
        with (EVIDENCE / 'boot.txt').open('w') as log:
            run(['xcrun', 'simctl', 'bootstatus', udid, '-b'], timeout=180, stdout=log, stderr=subprocess.STDOUT)
        run(['xcrun', 'simctl', 'install', udid, str(ROOT / 'examples/native/build/WandShowcaseNative.app')], timeout=60)
        with (EVIDENCE / 'info.txt').open('w') as log:
            run([WAND, '--udid', udid, 'info'], stdout=log)
        for orientation, limit in [('portrait', 180), ('landscape', 120)]:
            with (EVIDENCE / (orientation + '.txt')).open('w') as log:
                run(['bash', str(ROOT / 'examples/native/e2e.sh')], timeout=limit,
                    env=dict(env, WAND_NATIVE_ORIENTATION=orientation, WAND_EVIDENCE_DIR=str(EVIDENCE / orientation)),
                    stdout=log, stderr=subprocess.STDOUT)
    finally:
        try:
            with (EVIDENCE / 'processes.txt').open('w') as log:
                subprocess.run(['/bin/ps', '-axo', 'pid,ppid,%cpu,rss,comm'], stdout=log, timeout=5)
        except (subprocess.SubprocessError, OSError) as error:
            print('Process diagnostics unavailable:', error, file=sys.stderr)
        if udid:
            daemon_log = Path.home() / '.wand' / ('daemon-' + udid + '.log')
            try:
                if daemon_log.exists():
                    (EVIDENCE / 'daemon.txt').write_bytes(daemon_log.read_bytes()[-1024 * 1024:])
            except OSError as error:
                print('Daemon diagnostics unavailable:', error, file=sys.stderr)
            cleanup = []
            if boot_requested:
                cleanup.append((['xcrun', 'simctl', 'io', udid, 'screenshot', str(EVIDENCE / 'final.png')], 10, False))
            if (Path.home() / '.wand' / ('daemon-' + udid + '.sock')).exists():
                cleanup.append(([WAND, '--udid', udid, 'stop'], 10, True))
            if boot_requested:
                cleanup.append((['xcrun', 'simctl', 'shutdown', udid], 30, True))
            cleanup.append((['xcrun', 'simctl', 'delete', udid], 30, True))
            failures = []
            for args, limit, required in cleanup:
                try:
                    run(args, limit, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
                except (subprocess.SubprocessError, OSError) as error:
                    print('Cleanup failed:', args[:3], str(error), file=sys.stderr)
                    if required: failures.append(args[:3])
            (EVIDENCE / 'cleanup.json').write_text(json.dumps(dict(failures=failures), indent=2))
            if failures and sys.exc_info()[0] is None:
                raise RuntimeError('Owned simulator cleanup did not complete')


if __name__ == '__main__':
    main()
