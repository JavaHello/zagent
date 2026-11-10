#!/usr/bin/env python3
"""Search names execute exactly their named program, without fallback."""
import json
import os
from pathlib import Path
import subprocess
import tempfile

binary = Path(__file__).resolve().parents[1] / 'zig-out/bin/zagent'
with tempfile.TemporaryDirectory(prefix='zagent-search-dispatch-') as directory:
    root = Path(directory)
    executables = root / 'bin'
    executables.mkdir()
    for name in ('rg', 'grep', 'fd', 'find'):
        program = executables / name
        program.write_text(f'#!/bin/sh\nprintf "{name}-only\\n"\n')
        program.chmod(0o755)

    def run(name):
        result = subprocess.run(
            [str(binary), '--tool-worker', name,
             json.dumps({'pattern': 'needle', 'path': '.'})],
            cwd=root, env={**os.environ, 'PATH': str(executables)},
            capture_output=True, text=True, timeout=10)
        assert result.returncode == 0, result.stderr
        return json.loads(result.stdout)

    for name in ('rg', 'grep', 'fd', 'find'):
        result = run(name)
        assert not result['is_error'], result
        assert result['content'].strip() == f'{name}-only', result

    # A missing preferred executable must not run its available counterpart.
    for missing, available in (('rg', 'grep'), ('fd', 'find')):
        (executables / missing).unlink()
        result = run(missing)
        assert result['is_error'], result
        assert f'{available}-only' not in result['content'], result
        assert not run(available)['is_error']

    # The reverse direction must not switch programs either.
    for missing, available in (('grep', 'rg'), ('find', 'fd')):
        (executables / missing).rename(executables / available)
        assert run(missing)['is_error']

print('search exact dispatch and missing-program contracts passed')
