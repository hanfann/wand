#!/usr/bin/env python3
"""Offline OCR qualification: exact recall, geometry, confidence and bounded work.

Default is fast mode only. Accurate must be explicitly requested; its first
worker timeout stops that mode, retaining all remaining targets as skipped.
"""
import argparse
import json
import math
from pathlib import Path
import subprocess
import time


def score(target, observations, threshold, width=float('inf'), height=float('inf')):
    hits = [o for o in observations if o['text'].casefold() == target['text'].casefold()]
    exact = len(hits) == 1
    correct = exact and (target['x'] <= hits[0]['x'] + hits[0]['w'] / 2 <= target['x'] + target['w'] and
                        target['y'] <= hits[0]['y'] + hits[0]['h'] / 2 <= target['y'] + target['h'])
    visible = exact and (hits[0]['x'] >= 0 and hits[0]['y'] >= 0 and hits[0]['w'] > 0 and hits[0]['h'] > 0 and
                         hits[0]['x'] + hits[0]['w'] <= width + .5 and hits[0]['y'] + hits[0]['h'] <= height + .5)
    confident = correct and visible and hits[0].get('conf', 0) >= threshold
    return dict(text=target['text'], exact=exact, correct_center=correct, confident_center=confident,
                confidence=hits[0].get('conf') if exact else None, ambiguous=len(hits) > 1)


def evaluate(wand, corpus, directory, mode, samples=1, timeout=None, runner=subprocess.run):
    threshold = .8 if mode == 'fast' else .6  # Same thresholds as Wand's automatic OCR targeting.
    deadline = timeout if timeout is not None else (3.5 if mode == 'fast' else 5.5)
    screens, blocked = [], False
    for screen in corpus:
        for sample in range(samples):
            observations, error = [], None
            started = time.monotonic()
            if blocked:
                status, elapsed = 'skipped_after_timeout', None
            else:
                try:
                    process = runner([wand, '__ocr', str(directory / screen['file']),
                                      str(screen['width']), str(screen['height']), mode],
                                     capture_output=True, timeout=deadline)
                    if process.returncode != 0:
                        raise ValueError(f'worker exit {process.returncode}')
                    observations = json.loads(process.stdout)
                    if not isinstance(observations, list):
                        raise ValueError('worker reply is not an observation array')
                    for observation in observations:
                        if (not isinstance(observation.get('text'), str) or
                            not all(type(observation.get(key)) in (int, float) and
                                    math.isfinite(observation[key]) for key in ['x', 'y', 'w', 'h', 'conf'])):
                            raise ValueError('malformed observation')
                    status = 'ok'
                except subprocess.TimeoutExpired:
                    status, blocked = 'timeout', True
                except (ValueError, TypeError, AttributeError) as failure:
                    status, error, observations = 'error', str(failure), []
                elapsed = (time.monotonic() - started) * 1000
            targets = [score(target, observations, threshold, screen['width'], screen['height'])
                       for target in screen['targets']]
            screens.append(dict(file=screen['file'], sample=sample, status=status, error=error,
                                elapsed_ms=elapsed, observations=observations, targets=targets))
    targets = [target for screen in screens for target in screen['targets']]
    return dict(mode=mode, confidence_threshold=threshold, screens=screens,
                summary=dict(screens=len(screens), targets=len(targets),
                             attempted=sum(s['status'] != 'skipped_after_timeout' for s in screens),
                             timeouts=sum(s['status'] == 'timeout' for s in screens),
                             skipped=sum(s['status'] == 'skipped_after_timeout' for s in screens),
                             errors=sum(s['status'] == 'error' for s in screens),
                             **{key: sum(t[key] for t in targets) for key in
                                ['exact', 'correct_center', 'confident_center', 'ambiguous']}))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('wand', type=Path)
    parser.add_argument('corpus', type=Path, help='Manifest JSON or a directory containing manifest.json')
    parser.add_argument('--modes', nargs='+', choices=['fast', 'accurate'], default=['fast'])
    parser.add_argument('--samples', type=int, default=1)
    parser.add_argument('--output', type=Path)
    parser.add_argument('--minimum-recall', type=float, default=.95)
    parser.add_argument('--gate', choices=['exact', 'correct_center', 'confident_center'], default='confident_center')
    args = parser.parse_args()
    if args.samples < 1 or not 0 <= args.minimum_recall <= 1:
        parser.error('samples must be positive and recall must be between 0 and 1')
    manifest = args.corpus / 'manifest.json' if args.corpus.is_dir() else args.corpus
    corpus = json.loads(manifest.read_text())
    if not corpus or any(not screen['targets'] for screen in corpus):
        parser.error('corpus must contain screens and annotated targets')
    report = dict(schema=2, gate=args.gate, minimum_recall=args.minimum_recall, results={})
    for mode in dict.fromkeys(args.modes):
        result = evaluate(str(args.wand.resolve()), corpus, manifest.parent, mode, args.samples)
        report['results'][mode] = result
        print(mode, json.dumps(result['summary']), flush=True)
    output = args.output or manifest.parent / 'results.json'
    output.write_text(json.dumps(report, indent=2) + '\n')
    passed = all(result['summary'][args.gate] / result['summary']['targets'] >= args.minimum_recall
                 and not any(result['summary'][key] for key in ['timeouts', 'errors', 'skipped'])
                 for result in report['results'].values())
    if not passed:
        raise SystemExit(f'FAIL: {args.gate} recall gate; see {output}')


if __name__ == '__main__':
    main()
