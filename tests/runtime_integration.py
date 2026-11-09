#!/usr/bin/env python3
"""The foreground editor stays responsive while the agent is awaiting an API."""
import fcntl
import http.server
import json
import os
from pathlib import Path
import pty
import re
import select
import struct
import subprocess
import tempfile
import termios
import threading
import time
from mock_api import handle_planning, send_response

started = threading.Event()
release = threading.Event()
answers = []
turns = []


class API(http.server.BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass

    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers['Content-Length'])))
        if handle_planning(self, body):
            return
        results = [m for m in body['input'] if m.get('type') == 'function_call_output']
        if not body.get('tools'):
            text = json.dumps({'complete': True, 'reason': 'done'})
            output = [{'type': 'message', 'role': 'assistant', 'content': [
                {'type': 'output_text', 'text': text}]}]
        elif not results:
            turns.append(body)
            started.set()
            assert release.wait(10), 'foreground never released the request'
            output = [{'type': 'function_call', 'call_id': 'choice', 'name': 'ask_user',
                       'arguments': json.dumps({'question': 'Runtime choice?', 'options': [
                           {'label': 'Alpha'}, {'label': 'Beta', 'recommended': True}]})}]
        else:
            answers.append(results[-1]['output'])
            output = [{'type': 'message', 'role': 'assistant', 'content': [
                {'type': 'output_text', 'text': 'Background answer complete'}]}]
        send_response(self, body, {'status': 'completed', 'output': output})


server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), API)
threading.Thread(target=server.serve_forever, daemon=True).start()
binary = Path(__file__).resolve().parents[1] / 'zig-out/bin/zagent'
ansi = re.compile(rb'\x1b(?:\[[0-?]*[ -/]*[@-~]|[78])')
try:
    with tempfile.TemporaryDirectory(prefix='zagent-runtime-') as directory:
        env = dict(PATH='/usr/bin:/bin', HOME=directory, XDG_CONFIG_HOME=directory,
                   TERM='xterm-256color', AI_KEY='test', AI_MODEL='runtime-mock',
                   AI_MEMORY='0', AI_COMPACT_THRESHOLD='0', AI_MAX_VERIFICATIONS='1',
                   AI_URL=f'http://127.0.0.1:{server.server_port}/v1')
        master, slave = pty.openpty()
        fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack('HHHH', 16, 80, 0, 0))
        original = termios.tcgetattr(slave)
        process = subprocess.Popen([str(binary)], cwd=directory, env=env,
                                   stdin=slave, stdout=slave, stderr=slave)
        transcript = bytearray()

        def until(expected):
            deadline = time.monotonic() + 12
            while expected not in ansi.sub(b'', transcript):
                assert time.monotonic() < deadline, transcript.decode(errors='replace')
                assert process.poll() is None, transcript.decode(errors='replace')
                if select.select([master], [], [], 0.1)[0]:
                    transcript.extend(os.read(master, 65536))

        def send(keys, expected):
            # A command result may be replayed from history before the next
            # prompt enters raw mode. Let that transition finish before typing.
            time.sleep(.25)
            while select.select([master], [], [], 0)[0]:
                os.read(master, 65536)
            transcript.clear()
            os.write(master, keys)
            until(expected)

        try:
            until('❯ '.encode())
            os.write(master, b'first question\r')
            assert started.wait(8)
            until(b's \xc2\xb7 in ')
            assert b'thinking' in ansi.sub(b'', transcript), transcript
            send(b'/model\r\r', b'Model: runtime-mock')
            assert not release.is_set()
            send(b'/status\r\r', b'Account quota:')
            assert not release.is_set()
            send(b'/help\r\r', b'While running: commands remain available; new questions are queued')
            send(b'next question\r', b'Input queued for the next turn.')
            # Page keys must leave the editor usable, even during a blocked request.
            send(b'\x1b[5~\x1b[6~/model\r\r', b'Model: runtime-mock')
            release.set()
            until(b'Enter an option number or your own answer below')
            # Clear any command-menu input left by the preceding redraw.
            send(b'\x15' + b'1\r', b'Background answer complete')
            until('✓ Task completed'.encode())
            assert b'\x1b[1m\x1b[32m' + '  ✓ Task completed'.encode() + b'\x1b[0m' in transcript, transcript
            deadline = time.monotonic() + 8
            while not answers:
                assert time.monotonic() < deadline
                time.sleep(.05)
            assert 'User selected: Alpha' in answers[0], answers
            send(b'/quit\r\r', b'Goodbye!')
            assert process.wait(timeout=5) == 0
            assert termios.tcgetattr(slave) == original
            print('PASS: background requests, live commands, queued input, page keys, foreground choice and clean shutdown')
        finally:
            release.set()
            if process.poll() is None:
                process.kill()
                process.wait()
            os.close(master)
            os.close(slave)
finally:
    server.shutdown()
