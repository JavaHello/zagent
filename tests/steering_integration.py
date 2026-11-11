#!/usr/bin/env python3
"""A line typed while a task runs reaches the model inside that same task."""
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
from mock_api import send_response, trust_workspace

requests = []


def message(text):
    return [{'type': 'message', 'role': 'assistant', 'content': [
        {'type': 'output_text', 'text': text}]}]


class API(http.server.BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass

    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers['Content-Length'])))
        requests.append(body)
        results = [m for m in body['input'] if m.get('type') == 'function_call_output']
        if not body.get('tools'):
            output = message(json.dumps({'complete': True, 'reason': 'done'}))
        elif not results:
            # A tool that is still running when the user types: what the worker
            # does with the line is the point of this test.
            output = [{'type': 'function_call', 'call_id': 'slow', 'name': 'bash',
                       'arguments': json.dumps({'command': 'sleep 2; echo worked'})}]
        else:
            output = message('Adjusted without restarting')
        send_response(self, body, {'status': 'completed', 'output': output})


server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), API)
threading.Thread(target=server.serve_forever, daemon=True).start()
binary = Path(__file__).resolve().parents[1] / 'zig-out/bin/zagent'
ansi = re.compile(rb'\x1b(?:\[[0-?]*[ -/]*[@-~]|[78])')
try:
    with tempfile.TemporaryDirectory(prefix='zagent-steering-') as directory:
        env = dict(PATH='/usr/bin:/bin', HOME=directory, XDG_CONFIG_HOME=directory,
                   TERM='xterm-256color', AI_KEY='test', AI_MODEL='steering-mock',
                   AI_URL=f'http://127.0.0.1:{server.server_port}/v1')
        trust_workspace(directory, env)
        master, slave = pty.openpty()
        fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack('HHHH', 24, 100, 0, 0))
        original = termios.tcgetattr(slave)
        process = subprocess.Popen([str(binary)], cwd=directory, env=env,
                                   stdin=slave, stdout=slave, stderr=slave)
        transcript = bytearray()

        def until(expected):
            deadline = time.monotonic() + 12
            while expected not in ansi.sub(b'', transcript):
                assert time.monotonic() < deadline, transcript.decode(errors='replace')
                assert process.poll() is None, transcript.decode(errors='replace')
                if select.select([master], [], [], .1)[0]:
                    transcript.extend(os.read(master, 65536))

        def pump(seconds):
            deadline = time.monotonic() + seconds
            while time.monotonic() < deadline:
                if select.select([master], [], [], .05)[0]:
                    transcript.extend(os.read(master, 65536))

        try:
            until('❯ '.encode())
            os.write(master, b'long task please\r')
            # Wait for the tool call to be announced: the task is running now.
            until(b'worked')
            pump(.2)
            os.write(master, b'also update the docs\r')
            until(b'Input sent to the running task.')
            until('✓ Turn finished'.encode())
            pump(1)
            # Two requests only: the task that asked for the tool, and the one
            # that carried the line typed while the tool ran. A line left for a
            # new turn would have been a third.
            assert len(requests) == 2, [json.dumps(b)[:400] for b in requests]
            follow_up = json.dumps(requests[-1])
            assert 'also update the docs' in follow_up, follow_up
            assert 'function_call_output' in follow_up, follow_up
            assert ansi.sub(b'', transcript).count('✓ Turn finished'.encode()) == 1, transcript
            os.write(master, b'/quit\r\r')
            until(b'Goodbye!')
            assert process.wait(timeout=5) == 0
            assert termios.tcgetattr(slave) == original
            print('PASS: input typed during a tool call adjusted the running task')
        finally:
            if process.poll() is None:
                process.kill()
                process.wait()
            os.close(master)
            os.close(slave)
finally:
    server.shutdown()
