#!/usr/bin/env python3
"""Adversarial simulator-free CLI/MCP checks; never starts a real daemon."""
import base64
import json
import tempfile
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

# Summary is a wire-level option, not a client-side filter that might hide failure.
sequence = [['tap', '10', '20'], ['ui', 'diff']]
sequence_json = json.dumps(sequence)
def batch_cli(udid):
    results = []
    for flags, source in [([], sequence_json), (['--summary'], sequence_json), (['--summary'], '-')]:
        results.append(subprocess.run([wand, '--udid', udid, 'batch', *flags, source],
            input=sequence_json if source == '-' else None, capture_output=True, text=True, timeout=4))
    for args in [['--typo', sequence_json], ['--summary', sequence_json, 'extra'],
                 ['--summary', '[["tap","10","20"],["key","NaN"]]']]:
        invalid = subprocess.run([wand, '--udid', udid, 'batch', *args], capture_output=True, text=True, timeout=4)
        assert invalid.returncode != 0, invalid
    return results
results, received = exchange(batch_cli, lambda conn, _: conn.sendall(b'{"ok":true,"text":"final result"}\n'))
assert all(result.returncode == 0 and result.stdout == 'final result\n' for result in results)
assert received == [['batch', sequence_json], ['batch', '--summary', sequence_json], ['batch', '--summary', sequence_json]], received
print('PASS: CLI summary and stdin preserve commands; invalid options/steps send no input')

compact_calls = [
    dict(commands=sequence, summary=True), dict(commands=sequence, summary=False),
    dict(commands=sequence, summary='true'), dict(commands=[]),
    dict(commands=[['tap', '10', '20'], ['key', 'NaN']], summary=True),
    dict(commands=[['tap', 10, 20]], summary=True),
]
def compact_mcp(udid):
    messages = [dict(jsonrpc='2.0', id=i, method='tools/call', params=dict(name='run',
        arguments=dict(arguments, udid=udid))) for i, arguments in enumerate(compact_calls)]
    data = b''.join(json.dumps(message).encode() + b'\n' for message in messages)
    return subprocess.run([wand, 'mcp', '--compact'], input=data, capture_output=True, timeout=4)
result, received = exchange(compact_mcp, lambda conn, _: conn.sendall(b'{"ok":true,"text":"final result"}\n'))
responses = [json.loads(line) for line in result.stdout.splitlines()]
assert len(responses) == len(compact_calls)
assert [response['result']['isError'] for response in responses] == [False, False, True, True, True, True], responses
assert len(received) == 2 and received[0][:2] == ['batch', '--summary'] and received[1][0] == 'batch', received
assert [json.loads(command[-1]) for command in received] == [sequence, sequence]
print('PASS: compact MCP summary is optional; invalid batches are rejected before dispatch')

failure = 'completed 1/2\n2 FAIL ambiguous target 🌱\nstopped; inspect before retrying'
def summary_cli(udid):
    return subprocess.run([wand, '--udid', udid, 'batch', '--summary', sequence_json],
        capture_output=True, text=True, timeout=4)
result, received = exchange(summary_cli, lambda conn, _: conn.sendall(
    json.dumps(dict(ok=False, text=failure), ensure_ascii=False).encode() + b'\n'))
assert result.returncode != 0 and result.stderr == failure + '\n' and len(received) == 1, result
result, received = exchange(summary_cli, lambda conn, _: None)
assert result.returncode != 0 and 'may have run' in result.stderr and len(received) == 1, result
print('PASS: summary preserves exact failure text and never replays a lost reply')

preview_calls = [
    dict(path='/tmp/a b.png', previewMaxEdge=640, crop='10 20 300 400'),
    dict(previewMaxEdge=640), dict(previewMaxEdge=0), dict(previewMaxEdge=True),
    dict(crop='0 0 10 10'), dict(previewMaxEdge=640, crop='0 0 NaN 10'),
]
def preview_mcp(udid):
    messages = [dict(jsonrpc='2.0', id=i, method='tools/call', params=dict(name='screenshot',
        arguments=dict(arguments, udid=udid))) for i, arguments in enumerate(preview_calls)]
    data = b''.join(json.dumps(message).encode() + b'\n' for message in messages)
    return subprocess.run([wand, 'mcp'], input=data, capture_output=True, timeout=4)
result, received = exchange(preview_mcp, lambda conn, _: conn.sendall(b'{"ok":true,"text":"preview metadata"}\n'))
responses = [json.loads(line) for line in result.stdout.splitlines()]
assert [response['result']['isError'] for response in responses] == [False, False, True, True, True, True], responses
assert received == [['screenshot', '/tmp/a b.png', '--preview', '640', '--crop', '10', '20', '300', '400'],
                    ['screenshot', '--preview', '640']], received
print('PASS: preview options preserve path/crop; invalid MCP preview arguments send no input')

profile_json = json.dumps(['tap', '10', '20'])
def profile_cli(udid):
    results = []
    for source in [profile_json, '-']:
        results.append(subprocess.run([wand, '--udid', udid, 'profile', source],
            input=profile_json if source == '-' else None, capture_output=True, text=True, timeout=4))
    for invalid in ['["stop"]', '["profile","[]"]', '["tap","NaN","20"]',
                    json.dumps(['batch', '[["tap","10","20"],["key","NaN"]]'])]:
        result = subprocess.run([wand, '--udid', udid, 'profile', invalid],
                                capture_output=True, timeout=4)
        assert result.returncode != 0
    return results
profile_result = '{"schema":1,"ok":true,"result":"tapped","profile":{}}'
results, received = exchange(profile_cli, lambda conn, _: conn.sendall(
    json.dumps(dict(ok=True, text=profile_result)).encode() + b'\n'))
assert all(result.stdout == profile_result + '\n' and result.returncode == 0 for result in results)
assert received == [['profile', profile_json], ['profile', profile_json]], received
def profile_once(udid):
    return subprocess.run([wand, '--udid', udid, 'profile', profile_json],
                          capture_output=True, text=True, timeout=4)
result, received = exchange(profile_once, lambda conn, _: None)
assert result.returncode != 0 and 'may have run' in result.stderr and len(received) == 1
print('PASS: profile accepts argv/stdin, preflights all input and never replays a lost reply')

since_calls = [dict(path='/tmp/a.png', since='none'), dict(since='a' * 64, previewMaxEdge=640),
               dict(since=True), dict(since='bad'), dict(since='A' * 64)]
def since_mcp(udid):
    messages = [dict(jsonrpc='2.0', id=i, method='tools/call', params=dict(name='screenshot',
        arguments=dict(arguments, udid=udid))) for i, arguments in enumerate(since_calls)]
    return subprocess.run([wand, 'mcp'], input=b''.join(json.dumps(m).encode() + b'\n' for m in messages),
                          capture_output=True, timeout=4)
result, received = exchange(since_mcp, lambda conn, _: conn.sendall(b'{"ok":true,"text":"observation"}\n'))
responses = [json.loads(line) for line in result.stdout.splitlines()]
assert [r['result']['isError'] for r in responses] == [False, False, True, True, True]
assert received == [['screenshot', '/tmp/a.png', '--since', 'none'],
                    ['screenshot', '--preview', '640', '--since', 'a' * 64]], received
def since_cli(udid):
    good = subprocess.run([wand, '--udid', udid, 'screenshot', '--since', 'none'], capture_output=True, timeout=4)
    bad = subprocess.run([wand, '--udid', udid, 'batch', '[["tap","1","2"],["screenshot","--since","bad"]]'],
                         capture_output=True, timeout=4)
    assert good.returncode == 0 and bad.returncode != 0
result, received = exchange(since_cli, lambda conn, _: conn.sendall(b'{"ok":true,"text":"observation"}\n'))
assert received == [['screenshot', '--since', 'none']], received
print('PASS: screenshot tokens route exactly; malformed tokens and batch steps send no input')

# Final screenshots are attached in the same response; input is dispatched once.
fixture = (Path(__file__).resolve().parents[1] /
    'docs/validation/workflow-profiling-2026-11-10/ocr-source.png').read_bytes()
token = 'a' * 64
with tempfile.TemporaryDirectory(prefix='wand-mcp-image-') as directory:
    frame = str(Path(directory) / 'frame.png')
    def image_call(udid, *, compact=True, since='none', image=True, final=True):
        args = dict(udid=udid, image=image)
        if compact:
            args.update(commands=[['tap', '10', '20']] +
                ([['screenshot', frame, '--since', since]] if final else []), summary=True)
        else:
            args.update(path=frame, since=since)
        message = dict(jsonrpc='2.0', id=1, method='tools/call',
                       params=dict(name='run' if compact else 'screenshot', arguments=args))
        return subprocess.run([wand, 'mcp'] + (['--compact'] if compact else []),
            input=json.dumps(message).encode() + b'\n', capture_output=True, timeout=4)
    def image_reply(conn, command, *, changed=True, write=True, ok=True):
        is_batch = command[0] == 'batch'
        steps = json.loads(command[-1]) if is_batch else [command]
        expected = ['screenshot', frame, '--preview', '640', '--since', 'none' if changed else token]
        assert steps[-1] == expected, steps
        if is_batch: assert steps[:-1] == [['tap', '10', '20']]
        if write: Path(frame).write_bytes(fixture)
        observation = dict(full=frame, preview=frame, changed=changed, token=token,
                           previewPixelToPoint=dict(xScale=.5, yScale=.5, xOffset=0, yOffset=0))
        text = ('completed 2/2\n2 OK ' if is_batch else '') + json.dumps(observation)
        if not ok: text = 'completed 0/2\n1 FAIL target missing'
        conn.sendall(json.dumps(dict(ok=ok, text=text)).encode() + b'\n')
    for compact in (True, False):
        result, received = exchange(lambda u: image_call(u, compact=compact), image_reply)
        response = json.loads(result.stdout)['result']
        assert not response['isError'] and len(received) == 1
        assert [c['type'] for c in response['content']] == ['text', 'image']
        assert base64.b64decode(response['content'][1]['data']) == fixture
        assert 'previewPixelToPoint' in response['content'][0]['text']
    Path(frame).unlink()
    result, received = exchange(lambda u: image_call(u, since=token),
        lambda c, cmd: image_reply(c, cmd, changed=False, write=False))
    response = json.loads(result.stdout)['result']
    assert not response['isError'] and len(response['content']) == 1 and len(received) == 1
    for options in (dict(final=False), dict(image='true')):
        result, received = exchange(lambda u: image_call(u, **options), image_reply)
        assert json.loads(result.stdout)['result']['isError'] and not received
    for ok in (False, True):
        result, received = exchange(image_call, lambda c, cmd: image_reply(c, cmd, ok=ok, write=False))
        response = json.loads(result.stdout)['result']
        assert response['isError'] and len(response['content']) == 1 and len(received) == 1
        if ok: assert 'Commands completed; image delivery failed' in response['content'][0]['text']
print('PASS: inline MCP PNG is exact; unchanged omits image; validation/failure never replays input')
