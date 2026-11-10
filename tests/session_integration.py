#!/usr/bin/env python3
"""Session IDs survive CLI restarts and /new never overwrites an old session."""
import http.server
import json
import os
from pathlib import Path
import re
import subprocess
import tempfile
import threading
from mock_api import handle_planning, send_response, trust_workspace

requests = []


class API(http.server.BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass

    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers['Content-Length'])))
        if handle_planning(self, body):
            return
        requests.append(body)
        if ('first-session-marker' in json.dumps(body.get('input', []))
                and not any(item.get('type') == 'function_call_output'
                            for item in body.get('input', []))):
            send_response(self, body, {'status': 'completed', 'output': [
                {'type': 'function_call', 'id': 'fc_exit', 'call_id': 'exit_call',
                 'name': 'bash', 'arguments': json.dumps({'command': 'exit 42'})}]})
            return
        send_response(self, body, {'status': 'completed', 'output': [
            {'type': 'message', 'role': 'assistant', 'content': [
                {'type': 'output_text', 'text': 'Saved answer'}]}]})


binary = Path(__file__).resolve().parents[1] / 'zig-out/bin/zagent'
server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), API)
threading.Thread(target=server.serve_forever, daemon=True).start()
try:
    with tempfile.TemporaryDirectory(prefix='zagent-sessions-') as directory:
        env = dict(os.environ, HOME=directory, XDG_CONFIG_HOME=directory,
                   TERM='dumb', AI_KEY='test', AI_MODEL='session-mock',
                   AI_MEMORY='0', AI_MAX_VERIFICATIONS='0', AI_COMPACT_THRESHOLD='0',
                   AI_URL=f'http://127.0.0.1:{server.server_port}/v1')
        state = trust_workspace(directory, env)
        legacy_path = Path(directory) / 'ignored-session.json'
        legacy_path.write_text('not a valid snapshot')
        env['AI_SESSION_FILE'] = str(legacy_path)
        env.pop('AI_PROVIDER', None)

        def run(*args, stdin='', ok=True):
            result = subprocess.run([str(binary), *args], input=stdin, text=True,
                                    capture_output=True, cwd=directory, env=env, timeout=20)
            assert (result.returncode == 0) == ok, result.stderr
            return result.stdout + result.stderr

        def session_id(output):
            return re.search(r'(?:Session\s+|Session: )([a-f0-9]{32})', output)[1]

        def assert_failed_tool_status(body):
            output = next(m['output'] for m in body['input']
                          if m.get('type') == 'function_call_output')
            header, content = output.split('\n', 1)
            assert header.startswith('[tool_status ') and header.endswith(']'), output
            assert json.loads(header[len('[tool_status '):-1]) == {
                'is_error': True, 'exit_code': 42, 'timed_out': False, 'truncated': False}, output
            assert content == 'Exit code: 42\n(no output)', content

        first = session_id(run('first-session-marker'))
        path = state / 'sessions' / f'{first}.json'
        old = path.read_bytes()
        saved = json.loads(old)
        saved_tool = next(m for m in saved['messages'] if m['role'] == 'tool')
        assert saved_tool['tool_status'] == {
            'is_error': True, 'exit_code': 42, 'timed_out': False, 'truncated': False}, saved_tool
        assert_failed_tool_status(requests[-1])
        assert any(message.get('role') == 'tool'
                   and message.get('content') == 'Exit code: 42\n(no output)'
                   for message in saved['messages']), saved
        assert 'Exit code: 42' in json.dumps(requests[-1]), requests[-1]
        second = session_id(run(stdin='/new\n/session\n/quit\n'))
        assert second != first
        assert path.read_bytes() == old
        files = list(path.parent.glob('*.json'))
        assert len(files) == 3, files  # initial startup, /new, and the first run
        assert all(json.loads(p.read_text())['messages'] == [] for p in files if p != path)
        resumed = run('--resume', first, 'continue-session-marker')
        assert session_id(resumed) == first
        assert 'first-session-marker' in json.dumps(requests[-1]), requests[-1]
        assert 'Saved answer' in json.dumps(requests[-1]), requests[-1]
        assert 'Exit code: 42' in json.dumps(requests[-1]), requests[-1]
        assert_failed_tool_status(requests[-1])
        assert len(list(path.parent.glob('*.json'))) == 3
        run('--resume', first, stdin='/clear\n/quit\n')
        assert json.loads(path.read_text())['messages'] == []
        run('--resume', '0' * 32, ok=False)
        run('--resume', '../escape', ok=False)
        run('--resume', ok=False)
        assert len(list(path.parent.glob('*.json'))) == 3
        path.write_text('{')
        run('--resume', first, ok=False)
        assert path.read_text() == '{'
        assert legacy_path.read_text() == 'not a valid snapshot'
        print('PASS: automatic session IDs, /new isolation, CLI resume, clear, invalid and corrupt sessions')
finally:
    server.shutdown()
