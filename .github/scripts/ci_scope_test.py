import subprocess
import tempfile
import unittest
from pathlib import Path
from ci_scope import classify, needs_macos


class ScopeTests(unittest.TestCase):
    def test_docs_only(self):
        self.assertFalse(needs_macos(['README.md', 'skills/wand/SKILL.md', 'docs/validation/result.json', 'assets/demo.png']))

    def test_code_tests_workflow_and_unknown_files_require_macos(self):
        for path in ['Sources/wand/OCR.swift', 'Tests/WandTests/Test.swift', '.github/workflows/ci.yml',
                     '.github/scripts/ci_scope.py', 'Package.swift', 'examples/native/ci.py',
                     'docs/run.sh', 'assets/fixture.swift', 'new-file', '.gitignore', 'Tests/fixture.md',
                     'docs/validation/reliability-2026-11-10/ipad-final/type.png']:
            self.assertTrue(needs_macos(['README.md', path]), path)
        self.assertTrue(needs_macos([]))

    def test_missing_boundaries_and_manual_events_fail_open(self):
        for base, head, event in [('', 'b'*40, 'push'), ('0'*40, 'b'*40, 'push'),
                                  ('--bad', 'b'*40, 'push'), ('a'*40, 'b'*40, 'workflow_dispatch')]:
            self.assertTrue(classify(base, head, event, git=lambda *a, **k: self.fail('unexpected git call'))[0])

    def test_diff_failure_runs_macos(self):
        def fail(*args, **kwargs):
            raise subprocess.TimeoutExpired('git', 30)
        self.assertTrue(classify('a'*40, 'b'*40, 'push', git=fail)[0])

    def test_diff_uses_both_rename_paths_and_nul_delimiters(self):
        def git(args, **kwargs):
            self.assertIn('--no-renames', args)
            self.assertIn('-z', args)
            return b'Sources/old.swift\0docs/renamed.md\0'
        self.assertTrue(classify('a'*40, 'b'*40, 'pull_request', git=git)[0])
        required, _, paths = classify('a'*40, 'b'*40, 'push', git=lambda *a, **k: b'docs/a\nb.md\0')
        self.assertFalse(required)
        self.assertEqual(paths, ['docs/a\nb.md'])

    def test_real_git_diff_includes_deleted_code_on_rename(self):
        with tempfile.TemporaryDirectory(prefix='wand-ci-scope-') as folder:
            def git(args, **kwargs):
                return subprocess.check_output(args, cwd=folder, stderr=subprocess.DEVNULL, **kwargs)
            git(['git', 'init', '-q'])
            def commit():
                git(['git', 'add', '.'])
                git(['git', '-c', 'user.name=Wand test', '-c', 'user.email=wand@example.invalid',
                     '-c', 'commit.gpgsign=false', 'commit', '-qm', 'fixture'])
                return git(['git', 'rev-parse', 'HEAD']).decode().strip()
            Path(folder, 'README.md').write_text('initial')
            first = commit()
            Path(folder, 'README.md').write_text('docs update')
            docs = commit()
            self.assertFalse(classify(first, docs, 'push', git=git)[0])
            Path(folder, 'source.swift').write_text('source')
            code = commit()
            self.assertTrue(classify(docs, code, 'push', git=git)[0])
            Path(folder, 'source.swift').rename(Path(folder, 'source.md'))
            renamed = commit()
            self.assertTrue(classify(code, renamed, 'push', git=git)[0])


if __name__ == '__main__':
    unittest.main()
