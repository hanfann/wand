#!/usr/bin/env python3
"""Compile the production screenshot response code and replay a saved frame.

No simulator, image generator, external dependency, or source mutation is used.
"""
import argparse
import json
from pathlib import Path
import subprocess
import tempfile

p = argparse.ArgumentParser(description=__doc__)
p.add_argument('image', type=Path)
p.add_argument('--points', type=float, nargs=2, required=True)
p.add_argument('--output', type=Path, required=True)
a = p.parse_args()
root = Path(__file__).resolve().parent.parent
with tempfile.TemporaryDirectory(prefix='wand-observation-benchmark-') as directory:
    scratch = Path(directory)
    sources = []
    for relative in ['Sources/WandKit/ScreenshotOptions.swift', 'Sources/wand/ScreenshotPreview.swift',
                     'Sources/wand/ScreenshotObservation.swift', 'examples/observation-benchmark.swift']:
        source = scratch / Path(relative).name
        source.write_text((root / relative).read_text().replace('import WandKit\n', ''))
        sources.append(str(source))
    binary = scratch / 'benchmark'
    subprocess.run(['swiftc', '-O', *sources, '-o', str(binary)], check=True, timeout=60)
    result = subprocess.run([str(binary), str(a.image.resolve()), *map(str, a.points), directory],
                            check=True, capture_output=True, text=True, timeout=60)
    report = json.loads(result.stdout)
    a.output.write_text(json.dumps(report, indent=2) + '\n')
    print(json.dumps({k: v for k, v in report.items() if k != 'samples_ms'}, indent=2))
