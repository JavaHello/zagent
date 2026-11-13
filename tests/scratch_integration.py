#!/usr/bin/env python3
"""The scratch directory is created at startup, emptied by /new, and removed at exit."""
import http.server
import json
from pathlib import Path
import re
import shlex
import stat
import subprocess
import tempfile
import threading

from mock_api import send_response, trust_workspace

binary = Path(__file__).resolve().parents[1] / 'zig-out/bin/zagent'
requests = []
runs = []  # the scratch path each process's system prompt announced
workspace = None
phase = 'create'


def announced(body):
    """The one scratch path and the working directory the prompt names."""
    prompt = body.get('instructions', '') + json.dumps(
        [i for i in body['input'] if i.get('role') in ('system', 'developer')],
        ensure_ascii=False)
    names = [t.get('name') for t in body['tools']]
    assert 'temp_dir' not in names, names
    found = set(re.findall(r'[^\s"\\]*/zagent-[0-9a-f]{32}', prompt))
    assert len(found) == 1, prompt
    assert workspace in prompt, prompt
    path = found.pop()
    if path not in runs:
        runs.append(path)
    return path


def turn(body):
    """Everything the mock knows about the conversation that has run so far."""
    inputs = body['input']
    last_user = max(index for index, item in enumerate(inputs) if item.get('role') == 'user')
    calls = [item for item in inputs[last_user:] if item.get('type') == 'function_call']
    outputs = [item['output'] for item in inputs if item.get('type') == 'function_call_output']
    for result in outputs:
        status = json.loads(result)
        assert not status['is_error'], result
    return inputs[last_user]['content'], calls, outputs


class API(http.server.BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass

    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers['Content-Length'])))
        requests.append(body)
        path = announced(body)
        # The run is alive inside this handler, so its directory should be too.
        stat_result = Path(path).stat()
        assert stat.S_ISDIR(stat_result.st_mode), path
        assert stat.S_IMODE(stat_result.st_mode) == 0o700, path
        text, calls, outputs = turn(body)
        call = None
        if text in ('create scratch files', 'reuse scratch files'):
            if not calls:
                call = ('write', {'path': str(Path(path) / 'task.sh'),
                                  'content': 'printf scratch-reused; pwd'})
            elif len(calls) == 1:
                call = ('bash', {'command': 'bash ' + shlex.quote(str(Path(path) / 'task.sh'))})
            else:
                # The announced directory is writable and commands started there
                # run in the working directory.
                assert 'scratch-reused' in outputs[-1], outputs[-1]
                assert workspace in outputs[-1], outputs[-1]
        elif text == 'list scratch':
            if not calls:
                call = ('bash', {'command': 'ls -A ' + shlex.quote(path)})
            else:
                # /new emptied this process's directory; the path itself stays,
                # because the system prompt names one path for the whole run.
                assert 'task.sh' not in outputs[-1], outputs[-1]
                assert json.loads(outputs[-1])['output'] == '', outputs[-1]
        index = len(requests)
        output = ([{'type': 'function_call', 'call_id': f'scratch-{index}',
                    'name': call[0], 'arguments': json.dumps(call[1])}]
                  if call else [{'type': 'message', 'role': 'assistant', 'content': [
                      {'type': 'output_text', 'text': 'Done'}]}])
        send_response(self, body, {'status': 'completed', 'output': output})


server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), API)
threading.Thread(target=server.serve_forever, daemon=True).start()
try:
    with tempfile.TemporaryDirectory(prefix='zagent-scratch-test-') as directory:
        scratch_root = Path(directory, 'tmp')
        scratch_root.mkdir()
        workspace = str(Path(directory).resolve())
        env = {'PATH': '/usr/bin:/bin', 'HOME': directory, 'TMPDIR': str(scratch_root),
               'XDG_CONFIG_HOME': directory, 'TERM': 'dumb',
               'AI_URL': f'http://127.0.0.1:{server.server_port}/v1',
               'AI_MODEL': 'mock', 'AI_KEY': 'test'}
        state = trust_workspace(directory, env)

        def run(*args, stdin=''):
            result = subprocess.run([str(binary), *args], cwd=directory, env=env,
                                    input=stdin, text=True, capture_output=True, timeout=30)
            assert result.returncode == 0, result.stderr
            return result.stdout + result.stderr

        # One private directory per process, announced in the prompt and used
        # for the run's files. /new empties it without moving the path, and the
        # process takes the whole tree with it when it exits.
        output = run(stdin='create scratch files\n/new\nlist scratch\n/quit\n')
        assert len(runs) == 1, runs
        first = runs[0]
        assert first.startswith(str(scratch_root.resolve()) + '/'), first
        assert not Path(first).exists(), f'{first} outlived the run'
        # /new draws the opening report again, so the session the process is
        # in now is the one the last report names.
        sid = re.findall(r'Session\s+([a-f0-9]{32})', output)[-1]
        saved = json.loads((state / 'sessions' / f'{sid}.json').read_text())
        # The directory belongs to the process, so the session does not carry it.
        assert 'temp_dirs' not in saved, saved

        # A new process resumes the conversation but works in a directory of its
        # own: nothing is adopted, so two agents never share one path.
        run('--resume', sid, stdin='reuse scratch files\n/quit\n')
        assert len(runs) == 2 and runs[1] != first, runs
        assert not Path(runs[1]).exists(), runs[1]

        # Removed snapshot fields are rejected, never silently migrated.
        snapshot = state / 'sessions' / f'{sid}.json'
        current = snapshot.read_text()
        legacy = json.loads(current)
        legacy['temp_dirs'] = runs[:2]
        snapshot.write_text(json.dumps(legacy))
        rejected = subprocess.run(
            [str(binary), '--resume', sid], cwd=directory, env=env,
            input='/quit\n', text=True, capture_output=True, timeout=30)
        assert rejected.returncode != 0, rejected.stdout
        assert 'UnknownField' in rejected.stderr, rejected.stderr
        assert len(runs) == 2, runs
        assert json.loads(snapshot.read_text()) == legacy
        snapshot.write_text(current)

        # Clearing history keeps the process's directory and its files.
        run('--resume', sid, stdin='/clear\n/quit\n')
finally:
    server.shutdown()
    server.server_close()

print('scratch directory integration: ok')
