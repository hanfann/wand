#!/usr/bin/env python3
"""Adversarial simulator-free CLI/MCP checks; never starts a real daemon."""
import json
from pathlib import Path
import socket
import subprocess
import sys
import threading
import uuid

wand = str(Path(sys.argv[1]).resolve())

def exchange(run, responder):
    udid = 'protocol-' + uuid.uuid4().hex
    path = Path.home() / '.wand' / ('daemon-' + udid + '.sock')
    server = socket.socket(socket.AF_UNIX)
    server.bind(str(path)); server.listen(8); server.settimeout(.1)
    done = threading.Event()
    received = []
    failures = []
    def serve():
        while not done.is_set():
            try:
                conn, _ = server.accept()
            except socket.timeout:
                continue
            try:
                with conn:
                    conn.settimeout(3)
                    data = bytearray()
                    while not data.endswith(b'\n'):
                        chunk = conn.recv(8192)
                        if not chunk: break
                        data.extend(chunk)
                    if data:
                        command = json.loads(data)
                        received.append(command)
                        responder(conn, command)
            except Exception as error:
                failures.append(str(error))
    thread = threading.Thread(target=serve); thread.start()
    try:
        result = run(udid)
    finally:
        done.set(); thread.join(4); server.close(); path.unlink(missing_ok=True)
    assert not thread.is_alive() and not failures, failures
    return result, received

def cli(udid):
    return subprocess.run([wand, '--udid', udid, 'ping'], capture_output=True, text=True, timeout=4)

payload = ('漢字 🐱\n' * 20000)
wire = json.dumps(dict(ok=True, text=payload), ensure_ascii=False).encode() + b'\n'
def fragmented(conn, _):
    for start in range(0, len(wire), 137): conn.sendall(wire[start:start + 137])
result, received = exchange(cli, fragmented)
assert result.returncode == 0 and result.stdout == payload + '\n', result.stderr
assert received == [['ping']]
print('PASS: fragmented large UTF-8 response is exact')

result, received = exchange(cli, lambda conn, _: conn.sendall(b'{"ok":true,"text":"partial"}'))
assert result.returncode != 0 and 'may have run' in result.stderr and received == [['ping']]
print('PASS: unterminated reply fails without replay')

calls = [
    ('tap', {}), ('tap', {'x': 10}), ('swipe', {'x1': 0, 'y1': 0, 'x2': 'bad', 'y2': 0}),
    ('longpress', {}), ('dragdrop', {}), ('key', {'usage': True}),
    ('assert', {'selector': 'Save', 'cond': 'typo'}),
    ('key', {'usage': 42}), ('wait', {'selector': 'Save', 'timeoutMs': 125}),
    ('longpress', {'selector': '#save', 'seconds': .25}),
]
def mcp(udid):
    messages = [dict(jsonrpc='2.0', id=i, method='tools/call', params=dict(name=name,
        arguments=dict(arguments, udid=udid))) for i, (name, arguments) in enumerate(calls)]
    data = b''.join(json.dumps(message).encode() + b'\n' for message in messages)
    return subprocess.run([wand, 'mcp'], input=data, capture_output=True, timeout=4)
result, received = exchange(mcp, lambda conn, _: conn.sendall(b'{"ok":true,"text":"ok"}\n'))
assert result.returncode == 0, result.stderr
responses = [json.loads(line) for line in result.stdout.splitlines()]
assert len(responses) == len(calls)
assert all(response['result']['isError'] for response in responses[:7]), responses
assert received == [['key', '42'], ['wait', 'Save', '125'], ['longpress', '#save', '0.25']], received
print('PASS: invalid MCP calls send no input; numeric values and durations are preserved')
print('PASS: coalesced persistent MCP requests retain every response')
