#!/usr/bin/env python3
"""Conservatively skip macOS only for a known documentation-only git diff."""
import json
import os
from pathlib import PurePosixPath
import re
import subprocess


def documentation(path):
    p = PurePosixPath(path)
    # This saved capture is also an input to ScreenshotPreviewTests.
    if path == 'docs/validation/reliability-2026-11-10/ipad-final/type.png':
        return False
    if p.suffix == '.md' and (len(p.parts) == 1 or p.parts[0] in ('docs', 'skills')):
        return True
    if p.parts and p.parts[0] in ('docs', 'assets'):
        return p.suffix in ('.png', '.jpg', '.jpeg', '.gif', '.svg', '.json', '.txt')
    return path in ('LICENSE', 'THIRD_PARTY_NOTICES')


def needs_macos(paths):
    return not paths or any(not documentation(path) for path in paths)


def classify(base, head, event, git=subprocess.check_output):
    if event not in ('push', 'pull_request'):
        return True, 'manual or unknown event', []
    if not all(re.fullmatch(r'[0-9a-fA-F]{40,64}', value or '') and set(value) != {'0'} for value in (base, head)):
        return True, 'missing or invalid diff boundary', []
    try:
        # Disable rename detection so moving code into docs still includes deletion
        # of the original code path. NUL preserves spaces/newlines in filenames.
        raw = git(['git', 'diff', '--name-only', '-z', '--no-renames', base, head, '--'], timeout=30)
        paths = [path.decode('utf-8') for path in raw.split(b'\0') if path]
    except (subprocess.SubprocessError, OSError, UnicodeError):
        return True, 'diff unavailable; run full qualification', []
    required = needs_macos(paths)
    return required, 'code/unknown changes' if required else 'documentation only', paths


if __name__ == '__main__':
    required, reason, paths = classify(os.getenv('BASE_SHA'), os.getenv('HEAD_SHA'), os.getenv('EVENT_NAME'))
    print(json.dumps(dict(run_macos=required, reason=reason, changed_files=len(paths))))
    with open(os.environ['GITHUB_OUTPUT'], 'a') as output:
        output.write(f'run_macos={str(required).lower()}\n')
