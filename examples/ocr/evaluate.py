#!/usr/bin/env python3
"""Measure exact text recall and correct target centers, separately from speed.
No simulator required. Does not claim synthetic fonts represent every app.
"""
import json
from pathlib import Path
import subprocess
import sys
import time
wand, directory = str(Path(sys.argv[1]).resolve()), Path(sys.argv[2])
corpus = json.loads((directory / 'manifest.json').read_text())
report = {}
for mode in ('fast', 'accurate'):
    rows = []
    for screen in corpus:
        start = time.monotonic()
        try:
            result = subprocess.run([wand, '__ocr', str(directory / screen['file']), str(screen['width']), str(screen['height']), mode], capture_output=True, timeout=5.5)
            observations = json.loads(result.stdout) if result.returncode == 0 else []
        except subprocess.TimeoutExpired:
            observations = []
        elapsed = time.monotonic() - start
        for target in screen['targets']:
            hits = [o for o in observations if o['text'].casefold() == target['text'].casefold()]
            correct = len(hits) == 1 and target['x'] <= hits[0]['x']+hits[0]['w']/2 <= target['x']+target['w'] and target['y'] <= hits[0]['y']+hits[0]['h']/2 <= target['y']+target['h']
            rows.append(dict(file=screen['file'], text=target['text'], exact=len(hits)==1, correct_center=correct, seconds=elapsed,
                             recognized=[o['text'] for o in observations]))
    report[mode] = dict(targets=len(rows), exact=sum(r['exact'] for r in rows), correct_centers=sum(r['correct_center'] for r in rows), rows=rows)
    print(mode, {k:v for k,v in report[mode].items() if k!='rows'}, flush=True)
(directory / 'results.json').write_text(json.dumps(report, indent=2)+'\n')
# Targeted input uses accurate recognition; report fast observations separately.
assert report['accurate']['correct_centers'] / report['accurate']['targets'] >= .95, 'accurate OCR corpus recall/target gate failed'
