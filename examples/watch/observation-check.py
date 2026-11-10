#!/usr/bin/env python3
"""Verify inline/conditional observations on an already booted 40mm watch.

Settings must be at its root. Never boots, resets, or stops any simulator.
Use only an explicitly selected disposable fixture with required backups complete.
"""
import argparse
import base64
import json
from pathlib import Path
import select
import subprocess
import tempfile
import time


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('wand', type=Path)
    parser.add_argument('udid')
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[2]
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='wand-image-check-') as scratch:
        helper = Path(scratch) / 'image-samples'
        subprocess.run(['swiftc', str(root / 'examples/image-samples.swift'), '-o', str(helper)],
                       check=True, timeout=60)
        qualify(args, root, output, helper)


def qualify(args, root, output, helper):
    process = subprocess.Popen([str(args.wand.resolve()), 'mcp', '--compact'],
                               stdin=subprocess.PIPE, stdout=subprocess.PIPE)
    records = []

    def request(commands):
        message = dict(jsonrpc='2.0', id=len(records) + 1, method='tools/call',
                       params=dict(name='run', arguments=dict(udid=args.udid, commands=commands,
                                                             summary=True, image=True)))
        start = time.monotonic()
        process.stdin.write(json.dumps(message).encode() + b'\n')
        process.stdin.flush()
        assert select.select([process.stdout], [], [], 20)[0], 'MCP deadline'
        result = json.loads(process.stdout.readline())['result']
        elapsed = (time.monotonic() - start) * 1000
        assert not result['isError'], result
        text = result['content'][0]['text']
        meta = json.loads(text.split('\n', 1)[1].split(' OK ', 1)[1])
        images = [item for item in result['content'] if item['type'] == 'image']
        assert len(images) == int(meta['changed'])
        if images:
            assert base64.b64decode(images[0]['data']) == Path(meta['preview']).read_bytes()
            assert meta['previewPixelToPoint'] == dict(xScale=.5, yScale=.5, xOffset=0, yOffset=0)
        records.append(dict(commands=commands, elapsed_ms=elapsed, changed=meta['changed'],
                            images=len(images), token=meta['token']))
        return meta

    def compare(path, reference):
        reference = root / 'docs/validation/outcome-wait-preflight-2026-11-10' / reference
        result = subprocess.run([str(helper), '--region', '0', '.18', '1', '.82',
                                 str(path), str(reference)], capture_output=True,
                                check=True, timeout=10)
        values = json.loads(result.stdout)
        assert [(item['width'], item['height']) for item in values] == [(324, 394), (324, 394)]
        error = sum(abs(a - b) for a, b in zip(values[0]['samples'], values[1]['samples'])) / len(values[0]['samples'])
        assert error < .035, (str(path), error)
        return error

    try:
        path = output / 'repeated.png'
        previous, token = None, 'none'
        for _ in range(20):
            meta = request([['screenshot', str(path), '--since', token]])
            current = path.read_bytes()
            assert meta['changed'] == (current != previous)
            previous, token = current, meta['token']
        repeats = list(records)
        errors = []
        for cycle in range(5):
            for label, coordinates, reference in [
                ('detail', ['81', '70'], 'notifications.png'),
                ('root', ['20', '28'], 'settings-root.png'),
            ]:
                path = output / f'{cycle}-{label}.png'
                meta = request([['tap', *coordinates], ['screenshot', str(path), '--since', token]])
                assert meta['changed']
                token = meta['token']
                errors.append(compare(path, reference))
        meta = request([['screenshot', str(output / 'fresh-caller.png')]])
        assert meta['changed']
        report = dict(records=records, repeat_captures=20,
                      repeat_image_deliveries=sum(item['images'] for item in repeats),
                      repeated_p95_ms=sorted(item['elapsed_ms'] for item in repeats)[18],
                      verified_transitions=10, max_reference_error=max(errors),
                      inline_png_exact=True, mapping_exact=True, independent_caller_fresh=True)
        (output / 'result.json').write_text(json.dumps(report, indent=2) + '\n')
        print(json.dumps({key: value for key, value in report.items() if key != 'records'}, indent=2))
    finally:
        process.stdin.close()
        try:
            process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait()
        process.stdout.close()


if __name__ == '__main__':
    main()
