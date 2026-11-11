#!/usr/bin/env python3
"""The scratch directory is created at startup and named in the system prompt."""
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
runs = []  # the scratch path each run's system prompt announced
workspace = None
phase = 'create'
issued = 0


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
    return found.pop()


class API(http.server.BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass

    def do_POST(self):
        global issued
        body = json.loads(self.rfile.read(int(self.headers['Content-Length'])))
        requests.append(body)
        path = announced(body)
        if not runs or runs[-1] != path:
            runs.append(path)
        results = [i['output'] for i in body['input']
                   if i.get('type') == 'function_call_output']
        for result in results:
            status = json.loads(result.split('\n', 1)[0][len('[tool_status '):-1])
            assert not status['is_error'], result
        call = None
        if phase == 'create' and issued == 0:
            call = ('write', {'path': str(Path(path) / 'task.sh'),
                              'content': 'printf scratch-reused; pwd'})
        elif phase == 'create' and issued == 1:
            call = ('bash', {'command': 'bash ' + shlex.quote(str(Path(path) / 'task.sh'))})
        elif phase == 'create':
            # The announced directory is writable and commands started there run
            # in the working directory.
            assert 'scratch-reused' in results[-1], results[-1]
            assert workspace in results[-1], results[-1]
        if call:
            issued += 1
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

        output = run('create scratch files')
        sid = re.search(r'Session: ([a-f0-9]{32})', output)[1]
        snapshot = state / 'sessions' / f'{sid}.json'
        saved = json.loads(snapshot.read_text())
        # The directory belongs to the process, so the session does not carry it.
        assert 'temp_dirs' not in saved, saved

        # One private directory per run, under TMPDIR and announced in the prompt.
        assert len(runs) == 1, runs
        first = runs[0]
        assert first.startswith(str(scratch_root.resolve()) + '/'), first
        assert stat.S_IMODE(Path(first).stat().st_mode) == 0o700, first
        assert (Path(first) / 'task.sh').is_file(), first

        # A new process resumes the conversation but works in a directory of its
        # own: nothing is adopted, so two agents never share one path, and the
        # earlier directory keeps its files. A run that discarded nothing takes
        # its empty directory with it.
        phase = 'check'
        run('--resume', sid, 'reuse scratch files')
        assert len(runs) == 2 and runs[1] != first, runs
        assert not Path(runs[1]).exists(), runs[1]
        assert (Path(first) / 'task.sh').is_file(), 'scratch files outlive the run'

        # Snapshots written by the old build kept a temp_dirs list; they still
        # load, and their paths are not advertised again.
        legacy = json.loads(snapshot.read_text())
        legacy['temp_dirs'] = [first, runs[1]]
        snapshot.write_text(json.dumps(legacy))
        run('--resume', sid, 'resume a legacy snapshot')
        assert len(runs) == 3 and runs[2] not in (first, runs[1]), runs
        assert not Path(runs[2]).exists(), runs[2]

        # Clearing history keeps the process's paths; a new session gets its own.
        run('--resume', sid, stdin='/clear\n/quit\n')
        other = run(stdin='/quit\n')
        assert re.search(r'--resume ([a-f0-9]{32})', other)[1] != sid
finally:
    server.shutdown()
    server.server_close()

print('scratch directory integration: ok')
