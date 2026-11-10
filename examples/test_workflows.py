import importlib.util
import json
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location('workflows', Path(__file__).with_name('workflows.py'))
workflows = importlib.util.module_from_spec(spec)
spec.loader.exec_module(workflows)


class WorkflowTests(unittest.TestCase):
    def test_failures_excluded_and_exclusive_only(self):
        row = dict(workflow='nav', verified=True, phases={'settle': dict(exclusive_ms=80)}, daemon_ms=100)
        for key in ['wall_ms', 'verification_ms', 'cli_ms', 'daemon_cpu_ms', 'cli_calls',
                    'response_bytes', 'result_bytes', 'image_bytes']:
            row[key] = 10
        bad = {**row, 'verified': False, 'wall_ms': 99999}
        result = workflows.summarize([row, bad])['nav']
        self.assertEqual((result['attempted'], result['passed'], result['failed']), (2, 1, 1))
        self.assertEqual(result['wall_ms']['p95'], 10)
        self.assertEqual(result['phase_share'], {'settle': .8})

    def test_empty_and_percentile(self):
        self.assertIsNone(workflows.distribution([]))
        self.assertEqual(workflows.distribution(list(range(1, 101)))['p95'], 95)

    def test_dimension_mismatch(self):
        with self.assertRaises(ValueError):
            workflows.difference(dict(width=1, height=1), dict(width=2, height=1))

    def test_unverified_workflow_rejected_before_input(self):
        with self.assertRaisesRegex(ValueError, 'explicit outcome'):
            workflows.validate_scenario(dict(preflight=[dict(command=['info'])], workflows=[]))

    def test_arbitrary_app_text_scenario_needs_no_watch_or_screenshot(self):
        workflows.validate_scenario(dict(preflight=[dict(command=['assert', '#editor'])], workflows=[
            dict(name='edit', steps=[dict(command=['type', 'hello']),
                                     dict(command=['assert', '#editor', 'value=hello'])])]))

    def test_unknown_reference_rejected_before_input(self):
        with self.assertRaisesRegex(ValueError, 'unknown image'):
            workflows.validate_scenario(dict(preflight=[dict(image='screen.png', reference='missing')], workflows=[]))

    def test_shipped_scenarios_are_well_formed(self):
        root = Path(__file__).parent
        for path in [root / 'watch/settings-workflows.json', root / 'watch/settings-ocr.json',
                     root / 'native/text-workflow.json']:
            workflows.validate_scenario(json.loads(path.read_text()))


if __name__ == '__main__':
    unittest.main()
