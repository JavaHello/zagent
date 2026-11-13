#!/usr/bin/env python3
"""ESC cancels API waits and process groups, and only dismisses a question."""
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

blocked = threading.Event()
release = threading.Event()
requests = []
asked = False


class API(http.server.BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass

    def do_POST(self):
        global asked
        body = json.loads(self.rfile.read(int(self.headers['Content-Length'])))
        requests.append(body)
        text = 'Recovery complete'
        output = None
        if not body.get('tools'):
            text = json.dumps({'complete': True, 'reason': 'done'})
        else:
            users = [m for m in body['input'] if m.get('role') == 'user']
            query = str(users[-1].get('content', ''))
            if 'network wait' in query:
                blocked.set()
                release.wait(20)
            elif 'slow tool' in query:
                output = [{'type': 'function_call', 'call_id': 'slow', 'name': 'bash',
                           'arguments': json.dumps({'command': 'echo STARTED > started; sleep 3; echo BAD > survived'})}]
            elif 'choose now' in query and not asked:
                # Once only: the model here is a stub, and asking again after a
                # dismissal would test a looping question, not what Esc does.
                asked = True
                output = [{'type': 'function_call', 'call_id': 'choice', 'name': 'ask_user',
                           'arguments': json.dumps({'questions': [
                               {'question': 'Cancel this choice?', 'options': [
                                   {'label': 'Alpha'}, {'label': 'Beta'}]}]})}]
        if output is None:
            output = [{'type': 'message', 'role': 'assistant', 'content': [
                {'type': 'output_text', 'text': text}]}]
        try:
            send_response(self, body, {'status': 'completed', 'output': output})
        except (BrokenPipeError, ConnectionResetError):
            pass


server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), API)
threading.Thread(target=server.serve_forever, daemon=True).start()
binary = Path(__file__).resolve().parents[1] / 'zig-out/bin/zagent'
ansi = re.compile(rb'\x1b(?:\[[0-?]*[ -/]*[@-~]|[78])')
try:
    with tempfile.TemporaryDirectory(prefix='zagent-interrupt-') as directory:
        env = dict(PATH='/usr/bin:/bin', HOME=directory, XDG_CONFIG_HOME=directory,
                   TERM='xterm', AI_KEY='test', AI_MODEL='interrupt-mock',
                   AI_URL=f'http://127.0.0.1:{server.server_port}/v1')
        trust_workspace(directory, env)
        master, slave = pty.openpty()
        fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack('HHHH', 24, 100, 0, 0))
        original = termios.tcgetattr(slave)
        process = subprocess.Popen([str(binary)], cwd=directory, env=env,
                                   stdin=slave, stdout=slave, stderr=slave)
        transcript = bytearray()

        def until(expected):
            deadline = time.monotonic() + 10
            while expected not in ansi.sub(b'', transcript):
                assert time.monotonic() < deadline, transcript.decode(errors='replace')
                assert process.poll() is None, transcript.decode(errors='replace')
                if select.select([master], [], [], .1)[0]:
                    transcript.extend(os.read(master, 65536))

        def wait_for(predicate):
            deadline = time.monotonic() + 8
            while not predicate():
                assert time.monotonic() < deadline, transcript.decode(errors='replace')
                assert process.poll() is None, transcript.decode(errors='replace')
                if select.select([master], [], [], .05)[0]:
                    transcript.extend(os.read(master, 65536))

        def send(keys):
            time.sleep(.2)
            while select.select([master], [], [], 0)[0]:
                os.read(master, 65536)
            transcript.clear()
            os.write(master, keys)

        def stop():
            send(b'\x1b')
            until(b'Task interrupted (Esc)')
            assert b'Error: Canceled' not in ansi.sub(b'', transcript)

        def recover():
            send(b'\x15recovery question\r')
            until('✓ Turn finished'.encode())
            # Every recorded function call must have an output before replay.
            body = [r for r in requests if r.get('tools')][-1]
            ids = {m['call_id'] for m in body['input'] if m.get('type') == 'function_call_output'}
            for item in body['input']:
                if item.get('type') == 'function_call':
                    assert item['call_id'] in ids, body

        try:
            until('❯ '.encode())
            send(b'network wait\r')
            wait_for(blocked.is_set)
            send(b'queued question\r')
            until(b'Input sent to the running task.')
            send(b'/')
            until(b'/help  Show this help')
            send(b'\x1b')
            until('❯ /'.encode())
            assert b'Task interrupted' not in ansi.sub(b'', transcript)
            send(b'\x15')
            stop()
            # Esc cancels the line that was waiting for the running task, so
            # no request may carry it.
            assert not any('queued question' in json.dumps(body) for body in requests), requests
            release.set()
            recover()
            send(b'slow tool\r')
            wait_for(Path(directory, 'started').exists)
            # Arrow keys must not interrupt. Input is preserved across ESC.
            send(b'draft\x1b[D\x1b[C')
            stop()
            until('❯ draft'.encode())
            recover()
            time.sleep(3.2)
            assert not Path(directory, 'survived').exists(), 'tool descendant survived ESC'
            send(b'choose now\r')
            until(b'Enter confirm')
            # A question is a detour in the run: Esc backs out of it, the agent
            # decides for itself and the task carries on instead of dying.
            send(b'\x1b')

            # The dismissal comes back as a tool output, and a replayed screen
            # can repeat old lines but cannot fake a request: wait for the one
            # that carries it. That the run is still alive is the point — an
            # interruption would leave the question unanswered in the record.
            def dismissed():
                bodies = [r for r in requests if r.get('tools')]
                if not bodies:
                    return False
                return any(m.get('call_id') == 'choice' and 'dismissed' in m['output']
                           for m in bodies[-1]['input'] if m.get('type') == 'function_call_output')
            wait_for(dismissed)
            send(b'/quit\r\r')
            until(b'Goodbye!')
            assert process.wait(timeout=5) == 0
            assert termios.tcgetattr(slave) == original
            print('PASS: ESC cancels API and process group, only dismisses a question; replay and recovery work')
        finally:
            release.set()
            if process.poll() is None:
                process.kill()
                process.wait()
            os.close(master)
            os.close(slave)
finally:
    server.shutdown()
