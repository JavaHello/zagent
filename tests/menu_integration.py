#!/usr/bin/env python3
"""Exercise ask_user through a real PTY and a local Responses API stub."""
from mock_api import send_response, handle_planning, trust_workspace

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


class API(http.server.BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass

    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers['Content-Length'])))
        if handle_planning(self, body):
            return
        results = [m for m in body['input'] if m.get('type') == 'function_call_output']
        if not body.get('tools'):
            content = json.dumps({'complete': True, 'reason': 'Choice received'})
            output = [{'type': 'message', 'role': 'assistant',
                       'content': [{'type': 'output_text', 'text': content}]}]
        elif not results:
            output = [{'type': 'function_call', 'call_id': 'choice', 'name': 'ask_user',
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
               'AI_MEMORY': '0',
               'AI_URL': f'http://127.0.0.1:{server.server_port}/v1'}
        trust_workspace(directory, env)
        cases = [
            (b'\r', None, 'recommended option: Beta'),
            (b'\x1b[A\r', None, 'User selected: Alpha'),
            (b'1\r', None, 'User selected: Alpha'),
            (b'\x1b[B\r', '自己的方案'.encode() + b'\r', '自己的方案'),
            (b'\x03', None, 'dismissed without an answer'),
            (b'\x04', None, 'dismissed without an answer'),
        ]
        for keys, custom, expected in cases:
            previous_answers = len(answers)
            master, slave = pty.openpty()
            fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack('HHHH', 24, 80, 0, 0))
            original = termios.tcgetattr(slave)
            process = subprocess.Popen([str(binary), 'Ask me to choose'], cwd=directory,
                                       env=env, stdin=slave, stdout=slave, stderr=slave)
            transcript = bytearray()
            sent = False
            custom_sent = custom is None
            deadline = time.monotonic() + 15
            try:
                while process.poll() is None:
                    assert time.monotonic() < deadline, transcript.decode(errors='replace')
                    if select.select([master], [], [], 0.1)[0]:
                        transcript.extend(os.read(master, 65536))
                    if not sent and b'Enter confirm' in transcript:
                        os.write(master, keys)
                        sent = True
                    if sent and not custom_sent and b'choice' in transcript:
                        # The line editor probes the cursor column on startup.
                        if b'\x1b[6n' in transcript:
                            os.write(master, b'\x1b[1;1R')
                        os.write(master, custom)
                        custom_sent = True
                assert process.returncode == 0, transcript.decode(errors='replace')
                assert len(answers) == previous_answers + 1, answers
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
        print('PASS: recommendation, arrows, number keys, custom text, cancellation, terminal restoration and piped fallback')
finally:
    server.shutdown()
