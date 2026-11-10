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


def has_live_group(group):
    """Bounded verification for a group whose signal failed; zombies cannot run."""
    result = subprocess.run(['/bin/ps', '-axo', 'pgid=,stat='], capture_output=True,
                            text=True, timeout=2, check=True)
    rows = [line.split() for line in result.stdout.splitlines()]
    if not rows or any(len(row) != 2 or not row[0].isdigit() for row in rows):
        raise RuntimeError('cannot verify process-group cleanup from malformed process inventory')
    return any(int(pgid) == group and not state.startswith('Z') for pgid, state in rows)


def signal_group(group, sig):
    try:
        os.killpg(group, sig)
    except ProcessLookupError:
        pass
    except PermissionError:
        # macOS can refuse a late signal to an exiting group. Verify it has no
        # running members; never treat a live denied group as cleaned up.
        if has_live_group(group):
            raise


def run(args, timeout=60, **kwargs):
    print(time.strftime('%H:%M:%S'), shlex.join(map(str, args)), flush=True)
    process = subprocess.Popen(args, start_new_session=True, **kwargs)
    try:
        stdout, stderr = process.communicate(timeout=timeout)
    except BaseException as original:
        # Killing a shell alone leaves its compiler/test children consuming RAM.
        # The new session belongs exclusively to this invocation.
        cleanup_errors = []
        for sig, wait in [(signal.SIGTERM, 1), (signal.SIGKILL, 2)]:
            try:
                signal_group(process.pid, sig)
            except (OSError, subprocess.SubprocessError, RuntimeError) as error:
                cleanup_errors.append(str(error))
            try:
                process.wait(timeout=wait)
            except subprocess.TimeoutExpired:
                if sig == signal.SIGKILL:
                    cleanup_errors.append('owned parent did not exit after SIGKILL')
        if cleanup_errors:
            message = 'Owned process cleanup failed: ' + '; '.join(cleanup_errors)
            print(message, file=sys.stderr)
            if hasattr(original, 'add_note'):
                original.add_note(message)
        raise
    if process.returncode:
        raise subprocess.CalledProcessError(process.returncode, args, stdout, stderr)
    return subprocess.CompletedProcess(args, process.returncode, stdout, stderr)


def output(args, timeout=60):
    return run(args, timeout, stdout=subprocess.PIPE, text=True).stdout


def select_device(catalog):
    # Device-specific runtimes can share a version with the general iOS runtime.
    # Pick a compatible pair; never fall back to an unqualified foldable panel.
    preferred = ['iPhone 14', 'iPhone 16e', 'iPhone 17', 'iPhone 17 Pro',
                 'iPhone 16', 'iPhone 15', 'iPhone SE (3rd generation)']
    pairs = []
    for runtime in catalog['runtimes']:
        if not runtime.get('isAvailable') or not runtime['identifier'].split('.')[-1].startswith('iOS-'):
            continue
        supported = {d['identifier'] for d in runtime.get('supportedDeviceTypes', [])}
        for device in catalog['devicetypes']:
            if device['name'] in preferred and (not supported or device['identifier'] in supported):
                rank = (tuple(int(n) for n in runtime['version'].split('.')), -preferred.index(device['name']))
                pairs.append((rank, runtime, device))
    assert pairs, 'No available iOS runtime supports a qualified single-screen iPhone fixture'
    _, runtime, device = max(pairs, key=lambda pair: pair[0])
    return runtime, device


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
        runtime, preferred = select_device(catalog)
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
