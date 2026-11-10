import importlib.util
import json
from pathlib import Path
import subprocess
from types import SimpleNamespace
import unittest

spec = importlib.util.spec_from_file_location('evaluate', Path(__file__).with_name('evaluate.py'))
evaluate = importlib.util.module_from_spec(spec)
spec.loader.exec_module(evaluate)


class EvaluationTests(unittest.TestCase):
    target = dict(text='Save', x=0, y=0, w=100, h=50)
    observation = dict(text='Save', x=10, y=10, w=30, h=10, conf=.9)

    def corpus(self, count):
        return [dict(file=f'{i}.png', width=100, height=50, targets=[self.target]) for i in range(count)]

    def test_readable_low_confidence_is_not_a_targeting_pass(self):
        result = evaluate.score(self.target, [{**self.observation, 'conf': .5}], .8)
        self.assertTrue(result['exact'] and result['correct_center'])
        self.assertFalse(result['confident_center'])

    def test_wrong_geometry_and_duplicates_fail(self):
        self.assertFalse(evaluate.score(self.target, [{**self.observation, 'x': 200}], .8)['correct_center'])
        result = evaluate.score(self.target, [self.observation, self.observation], .8)
        self.assertTrue(result['ambiguous'])
        self.assertFalse(result['exact'] or result['confident_center'])

    def test_center_inside_target_does_not_excuse_offscreen_bounds(self):
        result = evaluate.score(self.target, [{**self.observation, 'x': -1}], .8, width=100, height=50)
        self.assertTrue(result['correct_center'])
        self.assertFalse(result['confident_center'])

    def test_first_timeout_stops_workers_but_keeps_missing_denominator(self):
        calls = []
        def runner(command, **kwargs):
            calls.append(command)
            raise subprocess.TimeoutExpired(command, kwargs['timeout'])
        result = evaluate.evaluate('wand', self.corpus(8), Path('/tmp'), 'accurate', runner=runner)
        self.assertEqual(len(calls), 1)
        self.assertEqual(result['summary']['targets'], 8)
        self.assertEqual(result['summary']['timeouts'], 1)
        self.assertEqual(result['summary']['skipped'], 7)
        self.assertEqual(result['summary']['confident_center'], 0)
        self.assertTrue(all(s['elapsed_ms'] is None for s in result['screens'][1:]))

    def test_repeated_samples_record_latency_once_per_screen(self):
        def runner(*args, **kwargs):
            return SimpleNamespace(returncode=0, stdout=json.dumps([self.observation]))
        result = evaluate.evaluate('wand', self.corpus(2), Path('/tmp'), 'fast', samples=3, runner=runner)
        self.assertEqual(result['summary']['confident_center'], 6)
        self.assertEqual(len(result['screens']), 6)

    def test_malformed_or_failed_worker_is_explicit(self):
        for reply in [SimpleNamespace(returncode=1, stdout=b''),
                      SimpleNamespace(returncode=0, stdout=b'{}'),
                      SimpleNamespace(returncode=0, stdout=b'[{"text":"Save"}]')]:
            result = evaluate.evaluate('wand', self.corpus(1), Path('/tmp'), 'fast', runner=lambda *a, **k: reply)
            self.assertEqual(result['summary']['errors'], 1)
            self.assertEqual(result['summary']['exact'], 0)


if __name__ == '__main__':
    unittest.main()
