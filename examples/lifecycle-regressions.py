#!/usr/bin/env python3
"""Simulator-free deadline/cancellation tests against the actual executable."""
import fcntl
import json
import os
from pathlib import Path
import select
import socket
import subprocess
import sys
import threading
import time
import uuid

wand = str(Path(sys.argv[1]).resolve())
root = Path.home() / '.wand'
root.mkdir(mode=0o700, exist_ok=True)

def target():
    return 'lifecycle-' + uuid.uuid4().hex[:16]

def cleanup(udid):
    for suffix in ('.sock', '.sock.startup.lock', '.sock.owner.lock', '.log'):
        (root / ('daemon-' + udid + suffix)).unlink(missing_ok=True)

def invoke(udid):
    start = time.monotonic()
    result = subprocess.run([wand, '--udid', udid, 'ping'], capture_output=True, text=True, timeout=3,
                            env=dict(os.environ, WAND_TEST_STARTUP_TIMEOUT_MS='200', WAND_TEST_DAEMON_STARTUP_STALL='1'))
    assert result.returncode != 0 and time.monotonic() - start < 1.5, result
    return result.stderr

udid = target()
try:
    with (root / ('daemon-' + udid + '.sock.startup.lock')).open('w') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        assert 'lock deadline' in invoke(udid)
    print('PASS: contended startup lock respects the total deadline')
    assert 'unready child stopped' in invoke(udid)
    # Child death must release its ownership lock, not just forget its PID.
    with (root / ('daemon-' + udid + '.sock.owner.lock')).open('w') as lock:
        deadline = time.monotonic() + 1
        while True:
            try:
                fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
                break
            except BlockingIOError:
                assert time.monotonic() < deadline, 'unready child survived'
                time.sleep(.01)
    print('PASS: stalled daemon startup kills its own child and releases ownership')
finally:
    cleanup(udid)

udid = target()
server = socket.socket(socket.AF_UNIX)
server.bind(str(root / ('daemon-' + udid + '.sock')))
server.listen(8)
server.settimeout(3)
received = []
connected = threading.Event()
disconnected = threading.Event()
errors = []
def serve():
    try:
        with server.accept()[0] as conn:
            conn.settimeout(3)
            command = json.loads(conn.makefile('rb').readline())
            received.append(command)
            connected.set()
            assert conn.recv(1) == b'', 'cancel did not close in-flight socket'
            disconnected.set()
        with server.accept()[0] as conn:
            conn.settimeout(3)
            command = json.loads(conn.makefile('rb').readline())
            received.append(command)
            conn.sendall(b'{"ok":true,"text":"healthy"}\n')
    except Exception as error:
        errors.append(str(error))
thread = threading.Thread(target=serve)
thread.start()
process = subprocess.Popen([wand, 'mcp'], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
def send(message):
    process.stdin.write(json.dumps(dict(jsonrpc='2.0', **message)).encode() + b'\n')
    process.stdin.flush()
def call(ident, name='info'):
    send(dict(id=ident, method='tools/call', params=dict(name=name, arguments=dict(udid=udid))))
try:
    call('active')
    assert connected.wait(2), 'active request never dispatched'
    call('queued')
    send(dict(method='notifications/cancelled', params=dict(requestId='queued')))
    start = time.monotonic()
    send(dict(method='notifications/cancelled', params=dict(requestId='active')))
    assert disconnected.wait(1), 'active cancellation did not release socket'
    assert time.monotonic() - start < .5
    call('recovery')
    process.stdin.close()
    process.wait(timeout=3)
    messages = [json.loads(line) for line in process.stdout.read().splitlines()]
    assert [m['id'] for m in messages] == ['recovery'], messages
    assert messages[0]['result']['content'][0]['text'] == 'healthy', messages
    thread.join(3)
    assert not thread.is_alive() and not errors, errors
    assert received == [['info'], ['info']], received
    print('PASS: active cancellation <500ms; queued request sends no input; no replay; next request succeeds')
finally:
    if process.poll() is None:
        process.kill(); process.wait(timeout=2)
    server.close()
    cleanup(udid)

messages = [b'broken\n', b'[]\n', b'{"jsonrpc":"2.0","id":true,"method":"ping"}\n',
            b'{"jsonrpc":"2.0","method":"tools/call","params":{"name":"info"}}\n',
            b'{"jsonrpc":"2.0","id":7,"method":"ping"}\n']
result = subprocess.run([wand, 'mcp'], input=b''.join(messages), capture_output=True, timeout=3)
responses = [json.loads(line) for line in result.stdout.splitlines()]
assert [r.get('error', {}).get('code') for r in responses] == [-32700, -32600, -32600, None], responses
assert responses[-1]['id'] == 7
print('PASS: malformed JSON/request/ID errors are explicit; notifications execute no input')

# Workers and a not-yet-ready daemon must die with their launching parent.
for operation, flag in [('__ax', 'WAND_TEST_AX_STALL'), ('__ocr', 'WAND_TEST_OCR_STALL'), ('__daemon', 'WAND_TEST_DAEMON_STARTUP_STALL')]:
    udid = target()
    code = 'import os,subprocess,sys,time; p=subprocess.Popen([sys.argv[1],sys.argv[2],"unused"],env=dict(os.environ,WAND_UDID=sys.argv[4],**{sys.argv[3]:"1"})); print(p.pid,flush=True); time.sleep(30)'
    parent = subprocess.Popen([sys.executable, '-c', code, wand, operation, flag, udid], stdout=subprocess.PIPE)
    child = int(parent.stdout.readline())
    try:
        time.sleep(.2)  # allow worker to install its parent monitor
        parent.kill(); parent.wait(timeout=2)
        deadline = time.monotonic() + 2
        while True:
            try: os.kill(child, 0)
            except ProcessLookupError: break
            assert time.monotonic() < deadline, f'{operation} survived its owner'
            time.sleep(.02)
    finally:
        if parent.poll() is None: parent.kill(); parent.wait(timeout=2)
        try: os.kill(child, 9)
        except ProcessLookupError: pass
    cleanup(udid)
    print(f'PASS: {operation} exits after parent death')
