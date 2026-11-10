#!/usr/bin/env python3
"""Measure app-independent scenarios on an already booted disposable simulator.

The JSON scenario supplies commands and explicit screenshot/text expectations.
Never implicitly boots, resets, retries input, or deletes a simulator. Compile
image-samples.swift before timing. Failed outcomes save partial evidence and stop
the run. References must be independently reviewed, not auto-calibrated.
"""
import argparse
import hashlib
import json
import math
from pathlib import Path
import statistics
import subprocess
import time


def distribution(values):
    if not values:
        return None
    ordered = sorted(values)
    return dict(n=len(values), median=statistics.median(values),
                p95=ordered[math.ceil(len(values) * .95) - 1], maximum=max(values))


def summarize(rows):
    result = {}
    for name in sorted({row['workflow'] for row in rows}):
        selected = [row for row in rows if row['workflow'] == name]
        passed = [row for row in selected if row['verified']]
        result[name] = dict(attempted=len(selected), passed=len(passed),
                            failed=len(selected) - len(passed))
        for key in ['wall_ms', 'verification_ms', 'cli_ms', 'daemon_ms', 'daemon_cpu_ms',
                    'cli_calls', 'response_bytes', 'result_bytes', 'image_bytes']:
            result[name][key] = distribution([row[key] for row in passed])
        phases = {}
        for row in passed:
            for key, value in row['phases'].items():
                phases[key] = phases.get(key, 0) + value['exclusive_ms']
        total = sum(row['daemon_ms'] for row in passed)
        result[name]['phase_share'] = {key: value / total if total else 0
                                        for key, value in sorted(phases.items(), key=lambda item: -item[1])}
    return result


def difference(a, b):
    if (a['width'], a['height']) != (b['width'], b['height']):
        raise ValueError('image dimensions changed')
    return sum(abs(x - y) for x, y in zip(a['samples'], b['samples'])) / len(a['samples'])


def validate_scenario(scenario):
    """Reject uncheckable/malformed scenarios before dispatching any command."""
    references = scenario.get('references', {})
    groups = [scenario['preflight']] + [item['steps'] for item in
             scenario['workflows'] + scenario.get('once', [])]
    for steps in groups:
        checks = 0
        for step in steps:
            if ('command' in step) == ('image' in step):
                raise ValueError('each step needs exactly one command or image')
            if 'command' in step:
                command = step['command']
                if not isinstance(command, list) or not command or not all(isinstance(x, str) for x in command):
                    raise ValueError('command must be a nonempty string array')
                checks += int('contains' in step or command[0] == 'assert')
            else:
                if step['reference'] not in references:
                    raise ValueError('unknown image reference')
                if not 0 < step.get('threshold', .025) < 1:
                    raise ValueError('image threshold must be between zero and one')
                checks += 1
        if not checks:
            raise ValueError('each workflow needs an explicit outcome assertion')


class Run:
    def __init__(self, args):
        self.args = args
        self.rows = []
        self.commands = []
        self.images = []
        self.verification_ms = 0
        self.scenario = json.loads(args.scenario.read_text())
        validate_scenario(self.scenario)
        self.output = args.output.resolve()
        self.output.mkdir(parents=True, exist_ok=False)
        paths = self.scenario.get('references', {})
        self.references = dict(zip(paths, self.decode([args.scenario.parent / path for path in paths.values()]))) if paths else {}

    def decode(self, paths):
        if self.args.image_helper is None:
            raise ValueError('image scenarios require --image-helper')
        region = self.scenario.get('image_region', [0, 0, 1, 1])
        return json.loads(subprocess.check_output([str(self.args.image_helper.resolve()),
                            '--region', *map(str, region),
                            *map(str, paths)], timeout=10))

    def command(self, command, expected_ok=True):
        start = time.perf_counter()
        process = subprocess.run([str(self.args.wand.resolve()), '--udid', self.args.udid,
                                  'profile', json.dumps(command)], capture_output=True, timeout=30)
        elapsed = (time.perf_counter() - start) * 1000
        raw = process.stdout if process.returncode == 0 else process.stderr
        try:
            reply = json.loads(raw)
        except ValueError as error:
            raise RuntimeError(f'non-profile reply; inspect before retrying: {raw[:500]!r}') from error
        row = dict(command=command, cli_ms=elapsed, response_bytes=len(process.stdout) + len(process.stderr), **reply)
        self.commands.append(row)
        if reply['ok'] != expected_ok or (process.returncode == 0) != expected_ok:
            raise RuntimeError(f'unexpected command outcome: {reply["result"]}')
        return reply['result']

    def verify(self, path, reference, threshold=.025, different=False):
        start = time.perf_counter()
        image = self.decode([path])[0]
        distance = difference(image, self.references[reference])
        valid = distance > threshold if different else distance < threshold
        self.images.append(dict(path=image['path'], bytes=image['bytes'], width=image['width'],
                                height=image['height'], reference=reference, distance=distance,
                                different=different, threshold=threshold, verified=valid))
        self.verification_ms += (time.perf_counter() - start) * 1000
        if not valid:
            raise RuntimeError(f'{path}: screenshot expectation failed against {reference}')

    def steps(self, steps, prefix):
        # Substitute only documented literal placeholders, including inside batch JSON.
        def expand(value):
            return value.replace('{output}', str(self.output)).replace('{sample}', prefix)
        checks = 0
        for step in steps:
            if 'command' in step:
                command = [expand(value) for value in step['command']]
                result = self.command(command, step.get('ok', True))
                if 'contains' in step:
                    if step['contains'] not in result:
                        raise RuntimeError(f'expected text missing: {step["contains"]!r}; actual: {result!r}')
                    checks += 1
                if command[0] == 'assert':
                    checks += 1
            elif 'image' in step:
                self.verify(expand(step['image']), step['reference'], step.get('threshold', .025), step.get('different', False))
                checks += 1
            else:
                raise ValueError('scenario step requires command or image')
        if not checks:
            raise ValueError('workflow needs an explicit outcome assertion; dispatch success is insufficient')

    def workflow(self, name, execute):
        self.commands, self.images, self.verification_ms = [], [], 0
        start = time.perf_counter()
        failure = None
        try:
            execute()
        except Exception as error:
            failure = str(error)
        row = dict(workflow=name, verified=failure is None, failure=failure,
                   wall_ms=(time.perf_counter() - start) * 1000, verification_ms=self.verification_ms,
                   commands=self.commands, images=self.images, cli_calls=len(self.commands), phases={})
        row['cli_ms'] = sum(item['cli_ms'] for item in self.commands)
        row['response_bytes'] = sum(item['response_bytes'] for item in self.commands)
        row['image_bytes'] = sum(item['bytes'] for item in self.images)
        for output, field in [('daemon_ms', 'elapsed_ms'), ('daemon_cpu_ms', 'daemon_cpu_ms'), ('result_bytes', 'result_bytes')]:
            row[output] = sum(item['profile'][field] for item in self.commands)
        for item in self.commands:
            for phase, metric in item['profile']['phases'].items():
                target = row['phases'].setdefault(phase, dict(calls=0, exclusive_ms=0))
                for key in target:
                    target[key] += metric[key]
        self.rows.append(row)
        self.save()
        print(name, 'PASS' if failure is None else 'FAIL', round(row['wall_ms']), 'ms', flush=True)
        if failure:
            raise RuntimeError(failure)

    def save(self):
        payload = dict(schema=1, udid=self.args.udid,
                       binary_sha256=hashlib.sha256(self.args.wand.read_bytes()).hexdigest(),
                       scenario=self.scenario,
                       notes=['Exclusive phases only are additive.', 'CPU excludes workers, OS and GPU.',
                              'Bytes are not model token counts; CLI calls are not agent turns.',
                              'Cold boot, daemon startup, fixture preparation and helper compilation excluded.',
                              'Coverage is limited to the supplied scenario and tested runtime.'],
                       summaries=summarize(self.rows), rows=self.rows)
        (self.output / 'results.json').write_text(json.dumps(payload, indent=2) + '\n')

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('wand', type=Path)
    parser.add_argument('--udid', required=True)
    parser.add_argument('--confirm-disposable', action='store_true', required=True)
    parser.add_argument('--image-helper', type=Path, help='Required only for image scenarios')
    parser.add_argument('--scenario', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--cycles', type=int, default=25)
    args = parser.parse_args()
    if args.cycles < 1:
        parser.error('cycles must be positive')
    devices = json.loads(subprocess.check_output(['xcrun', 'simctl', 'list', 'devices', 'booted', '-j'], timeout=15))
    matches = [(runtime, device) for runtime, devices in devices['devices'].items()
               for device in devices if device['udid'] == args.udid]
    if len(matches) != 1:
        parser.error('selected simulator must already be booted')
    run = Run(args)
    run.workflow('preflight', lambda: run.steps(run.scenario['preflight'], 'preflight'))
    for index in range(args.cycles):
        workflows = run.scenario['workflows']
        for workflow in (workflows if index % 2 == 0 else list(reversed(workflows))):
            run.workflow(workflow['name'], lambda: run.steps(workflow['steps'], f'{index}-{workflow["name"]}'))
    for workflow in run.scenario.get('once', []):
        run.workflow(workflow['name'], lambda: run.steps(workflow['steps'], workflow['name']))


if __name__ == '__main__':
    main()
