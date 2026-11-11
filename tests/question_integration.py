#!/usr/bin/env python3
"""A question owns the prompt rows: the menu answers it, the input box does not.

Two ask_user calls arrive in one message, so this also covers the batch: each
question takes the keyboard in turn, the last row of each menu is free text, and
nothing typed at the menu reaches the running task as guidance. A second turn
dismisses a question with Ctrl+C and the task carries on without it.
"""
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

answers = []
requests = []
recorded = set()


class API(http.server.BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass

    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers['Content-Length'])))
        previous = len([r for r in requests if r.get('tools')])
        requests.append(body)
        results = [m for m in body['input'] if m.get('type') == 'function_call_output']
        turn = previous + 1
        if not body.get('tools'):
            output = [{'type': 'message', 'role': 'assistant',
                       'content': [{'type': 'output_text', 'text': '{}'}]}]
        elif turn == 1:
            output = [
                {'type': 'function_call', 'call_id': 'first', 'name': 'ask_user',
                 'arguments': json.dumps({'question': 'First question?', 'options': [
                     {'label': 'Alpha'}, {'label': 'Beta', 'recommended': True}]})},
                {'type': 'function_call', 'call_id': 'second', 'name': 'ask_user',
                 'arguments': json.dumps({'question': 'Second question?', 'options': [
                     {'label': 'Gamma'}, {'label': 'Delta', 'recommended': True}]})},
            ]
        elif turn == 3:
            output = [{'type': 'function_call', 'call_id': 'only', 'name': 'ask_user',
                       'arguments': json.dumps({'question': 'Cancel this one?', 'options': [
                           {'label': 'Alpha'}, {'label': 'Beta', 'recommended': True}]})}]
        else:
            for result in results:
                # Every earlier result is replayed on each request; only the
                # new one belongs to this turn.
                if result['call_id'] in recorded:
                    continue
                recorded.add(result['call_id'])
                answers.append((result['call_id'], result['output']))
            output = [{'type': 'message', 'role': 'assistant',
                       'content': [{'type': 'output_text', 'text': 'Turn complete'}]}]
        send_response(self, body, {'status': 'completed', 'output': output})


server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), API)
threading.Thread(target=server.serve_forever, daemon=True).start()
binary = Path(__file__).resolve().parents[1] / 'zig-out/bin/zagent'
ansi = re.compile(rb'\x1b(?:\[[0-?]*[ -/]*[@-~]|[78])')
try:
    with tempfile.TemporaryDirectory(prefix='zagent-question-') as directory:
        env = dict(PATH='/usr/bin:/bin', HOME=directory, XDG_CONFIG_HOME=directory,
                   TERM='xterm-256color', AI_KEY='test', AI_MODEL='question-mock',
                   AI_URL=f'http://127.0.0.1:{server.server_port}/v1')
        trust_workspace(directory, env)
        master, slave = pty.openpty()
        fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack('HHHH', 24, 100, 0, 0))
        original = termios.tcgetattr(slave)
        process = subprocess.Popen([str(binary)], cwd=directory, env=env,
                                   stdin=slave, stdout=slave, stderr=slave)
        transcript = bytearray()

        def clean():
            return ansi.sub(b'', transcript)

        def until(predicate, expected):
            deadline = time.monotonic() + 12
            while not predicate():
                assert time.monotonic() < deadline, expected.decode() + '\n' + transcript.decode(errors='replace')
                assert process.poll() is None, transcript.decode(errors='replace')
                if select.select([master], [], [], 0.05)[0]:
                    transcript.extend(os.read(master, 65536))

        def drawn(text, mark=0):
            # A drawn option row, unlike the tool-call announcement above it,
            # which carries the labels as JSON.
            return text.encode() in ansi.sub(b'', transcript[mark:])

        def settle(seconds=0.1):
            time.sleep(seconds)

        try:
            until(lambda: clean().count(b'\xe2\x9d\xaf ') > 0, b'the prompt')

            # Turn one: two questions in one message.
            os.write(master, b'ask me twice\r')

            # The first menu has the keyboard: stray typing belongs to it, an
            # arrow key moves the selection, Enter answers.
            until(lambda: drawn('1) Alpha'), b'first question')
            settle()
            os.write(master, b'zz')
            os.write(master, b'\x1b[A\r')

            # The second question follows, and its last row types an answer.
            until(lambda: drawn('1) Gamma'), b'second question')
            settle()
            os.write(master, b'3\r')
            until(lambda: b'choice' in clean(), b'the free-text prompt')
            if b'\x1b[6n' in transcript:
                os.write(master, b'\x1b[1;1R')
            os.write(master, b'my own words\r')
            until(lambda: b'Turn complete' in clean(), b'the answer')
            until(lambda: len(answers) == 2, b'both tool results')

            assert answers[0][0] == 'first', answers
            assert 'User selected: Alpha' in answers[0][1], answers
            assert answers[1][0] == 'second', answers
            assert 'answered: my own words' in answers[1][1], answers
            # Nothing typed at a menu is guidance for the running task.
            assert b'Input sent to the running task' not in clean(), transcript
            # Both tool results reached the model in the same request.
            assert len([r for r in requests if r.get('tools')]) == 2, requests

            # Turn two: Ctrl+C dismisses the question and the task goes on.
            mark = len(transcript)
            os.write(master, b'cancel please\r')
            until(lambda: drawn('1) Alpha', mark), b'the cancelled question')
            settle()
            os.write(master, b'\x03')
            until(lambda: len(answers) == 3, b'the dismissed result')
            assert 'dismissed without an answer' in answers[2][1], answers

            os.write(master, b'/quit\r\r')
            until(lambda: b'Goodbye!' in transcript, b'the exit')
            assert process.wait(timeout=5) == 0
            assert termios.tcgetattr(slave) == original, 'raw terminal was not restored'
            print('PASS: questions share the prompt rows and take the keyboard, the last row '
                  'types an answer, Ctrl+C dismisses one, and menu keys never steer the task')
        finally:
            if process.poll() is None:
                process.kill()
                process.wait()
            os.close(master)
            os.close(slave)
finally:
    server.shutdown()
