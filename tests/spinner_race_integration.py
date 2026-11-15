#!/usr/bin/env python3
"""The progress line has one owner at a time.

A caller waiting on a sub-agent prints the run's self-check on its own progress
line, and at the same moment the sub-agent prints one of its own tool calls on
that same line — on the caller's terminal. Both of them stop the spinner to do
it, and a spinner stopped twice is a `std.Io.Future` cancelled twice, which the
io runtime does not allow: in a checked build it panics, in a release build it
frees the future twice and the io runtime dies later, somewhere else entirely.

There is no animation without a terminal, so the agent is given a pty here; the
suites that use pipes never reach this code at all. The race is a race, so the
run is repeated: one iteration that prints nothing alarming is not proof.
"""
import fcntl
import http.server
import json
import os
import pty
import re
import select
import struct
import subprocess
import sys
import tempfile
import termios
import threading
import time
from pathlib import Path

from mock_api import send_response, trust_workspace

binary = Path(__file__).resolve().parents[1] / 'zig-out/bin/zagent'
requests = []

# The child reports at its first boundary, the way `self_check_seconds = 0`
# arranges, and then runs a command — the caller prints the report while the
# child is printing its next call.
script = [
    ('subagent', {'task': 'Split the source tree into one file per tool.',
                  'title': 'Split the tree', 'self_check_seconds': 0, 'deadline_seconds': 40}),
    ('report', {'summary': 'two of the four tools are split'}),
    ('bash', {'command': 'sleep 0.3; echo split', 'timeout_seconds': 30}),
    ('answer', {'text': 'Final report: half done.'}),
    ('answer', {'text': 'Read the final report.'}),
]
index = 0
lock = threading.Lock()


class API(http.server.BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass

    def do_POST(self):
        global index
        body = json.loads(self.rfile.read(int(self.headers['Content-Length'])))
        with lock:
            requests.append(body)
            kind, payload = script[index] if index < len(script) else ('answer', {'text': 'done'})
            index += 1
        if kind == 'answer':
            output = [{'type': 'message', 'role': 'assistant',
                       'content': [{'type': 'output_text', 'text': payload['text']}]}]
        else:
            output = [{'type': 'function_call', 'call_id': f'{kind}-{index}',
                       'name': kind, 'arguments': json.dumps(payload)}]
        send_response(self, body, {'status': 'completed', 'output': output})


def plain(text):
    return re.sub(r'\x1b\[[0-9;?]*[A-Za-z]', '', text)


def run_once(server, directory, env, timeout=120):
    """One interactive run of zagent on a pty, ended with Ctrl-D at the prompt."""
    global index
    with lock:
        index = 0
        requests.clear()
    master, slave = pty.openpty()
    fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack('HHHH', 40, 100, 0, 0))
    proc = subprocess.Popen([str(binary), 'Split the tools'], cwd=directory, env=env,
                            stdin=slave, stdout=slave, stderr=slave, start_new_session=True)
    os.close(slave)
    out = bytearray()
    started = time.time()
    eof_sent = False
    try:
        while True:
            if proc.poll() is not None:
                break
            now = time.time() - started
            text = out.decode('utf-8', 'replace')
            if not eof_sent and now > 1 and 'Read the final report.' in plain(text):
                # The turn is over and the prompt has the keyboard; Ctrl-D is
                # how this program is asked to leave from there.
                os.write(master, b'\x04')
                eof_sent = True
            if now > timeout:
                break
            ready, _, _ = select.select([master], [], [], 0.1)
            if ready:
                try:
                    chunk = os.read(master, 65536)
                except OSError:
                    break
                if not chunk:
                    break
                out.extend(chunk)
        if proc.poll() is None:
            begin = time.time()
            while proc.poll() is None and time.time() - begin < 5:
                ready, _, _ = select.select([master], [], [], 0.1)
                if ready:
                    try:
                        chunk = os.read(master, 65536)
                    except OSError:
                        break
                    out.extend(chunk)
    finally:
        if proc.poll() is None:
            proc.kill()
        rc = proc.wait()
        os.close(master)
    return rc, out.decode('utf-8', 'replace')


server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), API)
threading.Thread(target=server.serve_forever, daemon=True).start()
try:
    with tempfile.TemporaryDirectory(prefix='zagent-line-') as directory:
        env = {'PATH': '/usr/bin:/bin', 'HOME': directory, 'XDG_CONFIG_HOME': directory,
               'TERM': 'xterm-256color', 'AI_URL': f'http://127.0.0.1:{server.server_port}/v1',
               'AI_MODEL': 'mock', 'AI_KEY': 'test', 'COLUMNS': '100', 'LINES': '40'}
        trust_workspace(directory, env)
        for attempt in range(1, 5):
            rc, transcript = run_once(server, directory, env)
            text = plain(transcript)
            trouble = [word for word in ('panic', 'unreachable', 'general protection',
                                         'segmentation fault', 'double free', 'use after free')
                       if word in text.lower()]
            assert not trouble, f'iteration {attempt}: {trouble}\n{text}'
            assert rc == 0, f'iteration {attempt}: exit {rc}\n{text}'
            # The line was really given up and taken back: the report the child
            # sent at its self-check is on the terminal, which it can only be if
            # the caller stopped the animation to print it.
            assert 'self-check' in text, f'iteration {attempt}: no self-check line\n{text}'
            assert 'two of the four tools are split' in text, f'iteration {attempt}\n{text}'
            assert 'Read the final report.' in text, f'iteration {attempt}\n{text}'
        print('PASS: the progress line is stopped and taken again by the caller and its child')
finally:
    server.shutdown()
    server.server_close()
