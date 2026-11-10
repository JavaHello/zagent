#!/usr/bin/env python3
"""Scratch paths persist independently of history and reuse existing host tools."""
import http.server
import json
import os
from pathlib import Path
import re
import shlex
import stat
import subprocess
import tempfile
import threading

from mock_api import handle_planning, send_response, trust_workspace

binary = Path(__file__).resolve().parents[1] / 'zig-out/bin/zagent'
requests = []
paths = []
phase = 'create'


class API(http.server.BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass

    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers['Content-Length'])))
        if handle_planning(self, body):
            return
        requests.append(body)
        assert 'temp_dir' in [t.get('name') for t in body['tools']]
        results = [i['output'] for i in body['input']
                   if i.get('type') == 'function_call_output']
        for result in results:
            header = result.split('\n', 1)[0]
            assert not json.loads(header[len('[tool_status '):-1])['is_error'], result
        n = len(results)
        prompt = json.dumps([i for i in body['input'] if i.get('role') == 'system'])
        call = None
        if phase == 'create':
            if n < 2:
                call = ('temp_dir', {})
            else:
                if not paths:
                    paths.extend(json.loads(r.split('\n', 1)[1])['path'] for r in results[:2])
                script = str(Path(paths[0]) / 'task.sh')
                if n == 2:
                    call = ('write', {'path': script, 'content': 'printf scratch-reused'})
                elif n == 3:
                    call = ('bash', {'command': 'bash ' + shlex.quote(script)})
                elif n == 4:
                    assert 'scratch-reused' in results[-1]
                    call = ('read', {'path': script})
                elif n == 5:
                    assert 'printf scratch-reused' in results[-1]
        elif phase == 'reuse':
            assert paths[0] in prompt, prompt
            if n == 0:
                call = ('bash', {'command': 'bash ' + shlex.quote(str(Path(paths[0]) / 'task.sh'))})
            else:
                assert 'scratch-reused' in results[-1]
        elif phase == 'deleted':
            assert paths[0] in prompt
            assert paths[1] not in prompt
        output = ([{'type': 'function_call', 'call_id': f'{phase}-{n}',
                    'name': call[0], 'arguments': json.dumps(call[1])}]
                  if call else [{'type': 'message', 'role': 'assistant', 'content': [
                      {'type': 'output_text', 'text': 'Done'}]}])
        send_response(self, body, {'status': 'completed', 'output': output})


server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), API)
threading.Thread(target=server.serve_forever, daemon=True).start()
try:
    with tempfile.TemporaryDirectory(prefix='zagent-scratch-test-') as directory:
        env = dict(os.environ, HOME=directory, XDG_STATE_HOME=directory,
                   XDG_CONFIG_HOME=directory, TMPDIR=directory, TERM='dumb',
                   AI_KEY='test', AI_MODEL='mock', AI_MEMORY='0',
                   AI_MAX_VERIFICATIONS='0', AI_COMPACT_THRESHOLD='0',
                   AI_URL=f'http://127.0.0.1:{server.server_port}/v1')
        env.pop('AI_PROVIDER', None)
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
        assert saved['temp_dirs'] == paths and len(set(paths)) == 2, saved
        for path in paths:
            assert Path(path).is_dir()
            assert stat.S_IMODE(Path(path).stat().st_mode) == 0o700
        # Clear history, not scratch state. Resume must expose paths even though
        # their original tool results no longer exist in the conversation.
        run('--resume', sid, stdin='/clear\n/quit\n')
        saved = json.loads(snapshot.read_text())
        assert saved['messages'] == [] and saved['temp_dirs'] == paths
        phase = 'reuse'
        run('--resume', sid, 'reuse scratch files')
        run('--resume', sid, stdin='/clear\n/quit\n')
        Path(paths[1]).rmdir()
        phase = 'deleted'
        run('--resume', sid, 'check surviving directories')
        assert json.loads(snapshot.read_text())['temp_dirs'] == paths[:1]
        assert not Path(paths[1]).exists()
        # A new session has independent runtime metadata.
        run(stdin='/quit\n')
        others = [p for p in snapshot.parent.glob('*.json') if p != snapshot]
        assert len(others) == 1
        legacy = json.loads(others[0].read_text())
        assert legacy.pop('temp_dirs') == []
        others[0].write_text(json.dumps(legacy))
        run('--resume', others[0].stem, stdin='/quit\n')
    print('temp directory integration: ok')
finally:
    server.shutdown()
