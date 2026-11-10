#!/usr/bin/env python3
"""Session IDs survive CLI restarts and /new never overwrites an old session."""
import fcntl
import http.server
import json
import os
from pathlib import Path
import re
import pty
import select
import struct
import subprocess
import tempfile
import termios
import threading
import time
from mock_api import send_response, trust_workspace

requests = []


class API(http.server.BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass

    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers['Content-Length'])))
        requests.append(body)
        if ('first-session-marker' in json.dumps(body.get('input', []))
                and not any(item.get('type') == 'function_call_output'
                            for item in body.get('input', []))):
            send_response(self, body, {'status': 'completed', 'output': [
                {'type': 'function_call', 'id': 'fc_exit', 'call_id': 'exit_call',
                 'name': 'bash', 'arguments': json.dumps({
                     'command': 'echo executed >> execution-count; exit 42'})}]})
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
        # Resume without asking a new question: restore visible execution
        # records, but neither contact the API nor execute the saved command.
        before_requests = len(requests)
        restored = re.sub(r'\x1b\[[0-?]*[ -/]*[@-~]', '',
                          run('--resume', first, stdin='/quit\n'))
        assert 'Restored session history' in restored, restored
        assert '❯ first-session-marker' in restored, restored
        assert '⚙ bash' in restored and 'execution-count' in restored, restored
        assert '✗ Exit code: 42' in restored, restored
        assert 'Saved answer' in restored, restored
        assert len(requests) == before_requests
        assert path.read_bytes() == old

        # Fullscreen startup must seed the Screen log too, not print history
        # before entering the alternate screen where it would disappear.
        master, slave = pty.openpty()
        fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack('HHHH', 50, 120, 0, 0))
        process = subprocess.Popen([str(binary), '--resume', first], cwd=directory,
                                   env=dict(env, TERM='xterm-256color'),
                                   stdin=slave, stdout=slave, stderr=slave)
        transcript = bytearray()
        ansi = re.compile(rb'\x1b(?:\[[0-?]*[ -/]*[@-~]|[78])')
        try:
            deadline = time.monotonic() + 10
            while b'End of restored history' not in ansi.sub(b'', transcript):
                assert time.monotonic() < deadline, transcript
                assert process.poll() is None, transcript
                if select.select([master], [], [], .1)[0]:
                    transcript.extend(os.read(master, 65536))
            visible = ansi.sub(b'', transcript)
            assert b'first-session-marker' in visible, visible
            assert b'execution-count' in visible, visible
            assert '✗ Exit code: 42'.encode() in visible, visible
            assert b'Saved answer' in visible, visible
            # History is painted before the editor enters raw mode; wait for
            # its final prompt cursor before sending EOF.
            while b'\x1b[50;3H\x1b[?25h' not in transcript:
                assert time.monotonic() < deadline, transcript
                if select.select([master], [], [], .1)[0]:
                    transcript.extend(os.read(master, 65536))
            os.write(master, b'\x04')
            deadline = time.monotonic() + 5
            while process.poll() is None:
                assert time.monotonic() < deadline, transcript
                if select.select([master], [], [], .1)[0]:
                    transcript.extend(os.read(master, 65536))
            assert process.returncode == 0, transcript
        finally:
            if process.poll() is None:
                process.kill()
                process.wait()
            os.close(master)
            os.close(slave)
        assert len(requests) == before_requests
        assert path.read_bytes() == old
        assert (Path(directory) / 'execution-count').read_text() == 'executed\n'

        resumed = run('--resume', first, 'continue-session-marker')
        assert 'Restored session history' not in resumed  # keep batch stdout clean
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
