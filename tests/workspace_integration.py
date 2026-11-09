#!/usr/bin/env python3
"""Real startup consent, canonical scoping and global-only persistence."""
import json
import os
from pathlib import Path
import pty
import select
import subprocess
import tempfile
import time
from mock_api import workspace_state

binary = Path(__file__).resolve().parents[1] / 'zig-out/bin/zagent'


def interact(directory, env, answer):
    master, slave = pty.openpty()
    process = subprocess.Popen([str(binary)], cwd=directory, env=env,
                               stdin=slave, stdout=slave, stderr=slave)
    output = bytearray()
    try:
        deadline = time.monotonic() + 10
        while b'[yes/No]' not in output:
            assert time.monotonic() < deadline, output
            assert process.poll() is None, output
            if select.select([master], [], [], .1)[0]:
                output.extend(os.read(master, 65536))
        os.write(master, answer + b'\n')
        if answer == b'yes':
            # TERM=dumb uses canonical input, so subsequent commands can queue.
            os.write(master, b'/memory\n/remember globally saved note\n/quit\n')
        while process.poll() is None:
            assert time.monotonic() < deadline, output
            if select.select([master], [], [], .1)[0]:
                output.extend(os.read(master, 65536))
        return process.returncode, output
    finally:
        if process.poll() is None:
            process.kill()
            process.wait()
        os.close(master)
        os.close(slave)


with tempfile.TemporaryDirectory(prefix='zagent-trust-') as temporary:
    root = Path(temporary)
    home = root / 'home'
    home.mkdir()
    first, second = root / 'first', root / 'second'
    first.mkdir()
    second.mkdir()
    env = dict(PATH='/usr/bin:/bin', HOME=str(home), XDG_STATE_HOME=str(home / 'state'),
               XDG_CONFIG_HOME=str(home), TERM='dumb', AI_KEY='test', AI_MODEL='mock',
               AI_MEMORY_AUTO='0', AI_MAX_VERIFICATIONS='0')
    state = workspace_state(first, env)

    def run(directory, *args, stdin='/quit\n'):
        return subprocess.run([str(binary), *args], cwd=directory, env=env,
                              input=stdin, text=True, capture_output=True, timeout=10)

    rejected = run(first, stdin='yes\n')
    assert rejected.returncode != 0 and 'Not trusted' in rejected.stderr
    assert not state.exists(), 'piped input must not grant trust'
    code, output = interact(first, env, b'no')
    assert code != 0 and not state.exists(), output

    legacy = first / '.zagent'
    (legacy / 'sessions').mkdir(parents=True)
    (legacy / 'memory.md').write_text('# zagent memory\n- legacy durable note\n')
    session_id = 'a' * 32
    snapshot = {'version': 1, 'workspace': str(first.resolve()), 'messages': []}
    (legacy / 'sessions' / f'{session_id}.json').write_text(json.dumps(snapshot))
    code, output = interact(first, env, b'yes')
    assert code == 0, output
    assert b'legacy durable note' not in output, output
    assert (state / 'trusted').read_text() == str(first.resolve())
    assert 'globally saved note' in (state / 'memory.md').read_text()
    assert json.loads((legacy / 'sessions' / f'{session_id}.json').read_text()) == snapshot
    resumed = run(first, '--resume', session_id, stdin='/memory\n/quit\n')
    assert resumed.returncode != 0, 'local sessions must not be imported'
    assert not (state / 'sessions' / f'{session_id}.json').exists()
    sessions = list((state / 'sessions').glob('*.json'))
    assert len(sessions) == 1
    resumed = run(first, '--resume', sessions[0].stem, stdin='/memory\n/quit\n')
    assert resumed.returncode == 0, resumed.stderr
    assert 'Trust this directory?' not in resumed.stderr
    assert 'globally saved note' in resumed.stdout + resumed.stderr
    assert 'legacy durable note' not in resumed.stdout + resumed.stderr
    assert len(list((state / 'sessions').glob('*.json'))) == 1

    alias = root / 'alias'
    alias.symlink_to(first, target_is_directory=True)
    assert run(alias).returncode == 0, 'symlink aliases use canonical identity'
    assert run(second).returncode != 0, 'trust must not spread to other directories'
    assert not workspace_state(second, env).exists()
    (state / 'trusted').write_text(str(second.resolve()))
    assert run(first).returncode != 0, 'stored full path must match too'
    assert run(second, '--help').returncode == 0
    assert run(second, '--version').returncode == 0
    print('PASS: explicit trust, rejection, piped denial, global-only persistence, canonical aliases and isolation')
