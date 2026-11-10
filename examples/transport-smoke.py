#!/usr/bin/env python3
"""Simulator-free protocol checks. Usage: python3 examples/transport-smoke.py PATH_TO_WAND"""
import json
import os
from pathlib import Path
import socket
import subprocess
import sys
import threading
import uuid

wand = str(Path(sys.argv[1]).resolve())
# Pretend to be a daemon that accepts a command and loses its reply. The client
# must fail promptly without starting/replaying another daemon or command.
udid = 'test-' + uuid.uuid4().hex
directory = Path.home() / '.wand'
directory.mkdir(mode=0o700, exist_ok=True)
path = str(directory / ('daemon-' + udid + '.sock'))
server = socket.socket(socket.AF_UNIX)
server.bind(path)
server.listen(2)
server.settimeout(3)
received = []

def lose_reply():
    try:
        connection, _ = server.accept()
        with connection:
            connection.settimeout(3)
            request = bytearray()
            while not request.endswith(b'\n'):
                chunk = connection.recv(4096)
                if not chunk:
                    raise RuntimeError('client closed before sending its command')
                request.extend(chunk)
            received.append(json.loads(request))
        try:
            extra, _ = server.accept()
            received.append('REPLAY')
            extra.close()
        except socket.timeout:
            pass
    except Exception as error:
        received.append(str(error))

thread = threading.Thread(target=lose_reply)
thread.start()
try:
    result = subprocess.run([wand, '--udid', udid, 'tap', '20', '30'], capture_output=True, text=True, timeout=5)
    assert result.returncode != 0 and 'may have run' in result.stderr, result
    thread.join(timeout=4)
    assert received == [['tap', '20', '30']], received
    print('PASS: lost reply fails without replaying input')
finally:
    server.close()
    Path(path).unlink(missing_ok=True)

requests = '\n'.join(json.dumps(message) for message in [
    {'jsonrpc': '2.0', 'id': 1, 'method': 'initialize'},
    {'jsonrpc': '2.0', 'id': 2, 'method': 'tools/list'},
]) + '\n'
catalogs = []
for mode in [[], ['--compact']]:
    response = subprocess.run([wand, 'mcp', *mode], input=requests, capture_output=True, text=True, timeout=5)
    assert response.returncode == 0, response.stderr
    messages = [json.loads(line) for line in response.stdout.splitlines()]
    tools = next(message['result']['tools'] for message in messages if message['id'] == 2)
    assert all('udid' in tool['inputSchema']['properties'] for tool in tools)
    catalogs.append(tools)
assert len(catalogs[1]) == 1 and catalogs[1][0]['name'] == 'run'
sizes = [len(json.dumps(catalog, separators=(',', ':'))) for catalog in catalogs]
assert sizes[1] < 1000, sizes
print('PASS: full and compact MCP catalogs support explicit targets')
print('Catalog bytes: {} -> {} ({:.1%} reduction); {} -> {} tools'.format(
    sizes[0], sizes[1], 1 - sizes[1] / sizes[0], len(catalogs[0]), len(catalogs[1])))
