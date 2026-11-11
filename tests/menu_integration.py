#!/usr/bin/env python3
"""Exercise ask_user through a real PTY and a local Responses API stub."""
from mock_api import send_response, trust_workspace

import http.server
import json
import re
import os
from pathlib import Path
import pty
import select
import struct
import subprocess
import tempfile
import termios
import threading
import time
import fcntl

binary = Path(__file__).resolve().parents[1] / 'zig-out/bin/zagent'
answers = []
requests = []
task_title = 'Carry out the task · ' + '题' * 58
assert len(task_title) == 79
task_description = '先明确方案，再按选择执行。'


class API(http.server.BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass

    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers['Content-Length'])))
        requests.append(body)
        assert body.get('tools'), 'unexpected separate planning or summarization request'
        results = [m for m in body['input'] if m.get('type') == 'function_call_output']
        if not results:
            output = [{'type': 'function_call', 'call_id': 'task', 'name': 'announce_task',
                       'arguments': json.dumps({'title': task_title,
                                                'description': task_description})},
                      {'type': 'function_call', 'call_id': 'choice', 'name': 'ask_user',
                       'arguments': json.dumps({'question': '选择方案？', 'options': [
                           {'label': 'Alpha'}, {'label': 'Beta', 'recommended': True}]})}]
        else:
            answers.append(results[-1]['output'])
            output = [{'type': 'message', 'role': 'assistant',
                       'content': [{'type': 'output_text', 'text': 'Choice received'}]}]
        send_response(self, body, {'status': 'completed', 'output': output})


server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), API)
threading.Thread(target=server.serve_forever, daemon=True).start()
try:
    with tempfile.TemporaryDirectory(prefix='zagent-menu-') as directory:
        env = {'PATH': '/usr/bin:/bin', 'HOME': directory, 'XDG_CONFIG_HOME': directory,
               'TERM': 'xterm-256color', 'AI_KEY': 'test', 'AI_MODEL': 'mock',
               'AI_URL': f'http://127.0.0.1:{server.server_port}/v1'}
        trust_workspace(directory, env)
        cases = [
            (b'\r', [], 'recommended option: Beta'),
            (b'\x1b[A\r', [], 'User selected: Alpha'),
            (b'1\r', [], 'User selected: Alpha'),
            (b'\x1b[B\r', [(b'choice', '自己的方案'.encode() + b'\r')], '自己的方案'),
            # Esc in the free-text row steps back to the options and the menu is
            # drawn again; Enter then takes the recommendation.
            (b'\x1b[B\r', [(b'choice', b'\x1b'), (b'Enter confirm', b'\r')], 'recommended option: Beta'),
            # Ctrl+C is not a way out of a question: it is ignored, and the
            # arrow that follows is what answers.
            (b'\x03\x1b[A\r', [], 'User selected: Alpha'),
            (b'\x1b', [], 'dismissed without an answer'),
            (b'\x04', [], 'dismissed without an answer'),
        ]
        for keys, custom, expected in cases:
            previous_answers = len(answers)
            previous_requests = len(requests)
            master, slave = pty.openpty()
            fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack('HHHH', 24, 80, 0, 0))
            original = termios.tcgetattr(slave)
            process = subprocess.Popen([str(binary), 'Ask me to choose'], cwd=directory,
                                       env=env, stdin=slave, stdout=slave, stderr=slave)
            transcript = bytearray()
            sent = False
            # Each step waits for its marker before typing: the free-text row and
            # the menu that Esc brings back look nothing alike.
            steps = list(custom)
            typed = 0
            deadline = time.monotonic() + 15
            try:
                while process.poll() is None:
                    assert time.monotonic() < deadline, transcript.decode(errors='replace')
                    if select.select([master], [], [], 0.1)[0]:
                        transcript.extend(os.read(master, 65536))
                    if not sent and b'Enter confirm' in transcript:
                        os.write(master, keys)
                        sent = True
                    while sent and steps and steps[0][0] in transcript[typed:]:
                        _, payload = steps.pop(0)
                        # The line editor probes the cursor column on startup.
                        if b'\x1b[6n' in transcript[typed:]:
                            os.write(master, b'\x1b[1;1R')
                        os.write(master, payload)
                        typed = len(transcript)
                assert process.returncode == 0, transcript.decode(errors='replace')
                assert len(answers) == previous_answers + 1, answers
                assert len(requests) == previous_requests + 2, requests
                assert task_description.encode() in transcript, transcript
                assert expected in answers[-1], answers
                assert termios.tcgetattr(slave) == original, 'raw terminal was not restored'
                titles = re.findall(rb'\x1b\]2;([^\x07]*)\x07', transcript)
                assert any(b'Carry out the task' in title for title in titles), titles
                assert all(b'Ask me to choose' not in title for title in titles), titles
                assert all(len(title.decode('utf-8')) < 80 for title in titles), titles
            finally:
                if process.poll() is None:
                    process.kill()
                    process.wait()
                os.close(master)
                os.close(slave)
        piped = subprocess.run([str(binary), 'Ask me to choose'], cwd=directory, env=env,
                               input='', capture_output=True, text=True, timeout=15)
        assert piped.returncode == 0, piped.stderr
        assert 'recommended option: Beta' in answers[-1], answers
        assert 'Enter confirm' not in piped.stdout + piped.stderr
        assert piped.stdout.count(task_description) == 1, piped.stdout
        assert '\x1b]2;' not in piped.stderr, piped.stderr
        print('PASS: recommendation, arrows, number keys, custom text, Esc in the free-text '
              'row stepping back, Ctrl+C ignored, Esc/Ctrl+D cancellation, terminal '
              'restoration and piped fallback')
finally:
    server.shutdown()
