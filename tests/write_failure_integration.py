#!/usr/bin/env python3
"""A connection killed under a request is replaced, not reused.

A keep-alive connection the server has dropped fails at the write, and the write
is the first thing a request does: no answer text has been shown yet, so the
request may be sent again on a fresh connection. What must never happen is that
the dead socket stays in the pool and swallows every request that follows it.
"""
import http.server
import json
import socket
import struct
import subprocess
import tempfile
import threading
import time
from pathlib import Path

from mock_api import send_response, trust_workspace

binary = Path(__file__).resolve().parents[1] / 'zig-out/bin/zagent'
state = {'mode': 'killed-after-tool', 'requests': [], 'connections': 0}
PARTIAL = 'half an answer'
ANSWER = 'recovered answer'
RST = struct.pack('ii', 1, 0)


def completed(text):
    return {'status': 'completed', 'output': [{'type': 'message', 'role': 'assistant',
            'content': [{'type': 'output_text', 'text': text}]}]}


def call(name, arguments):
    return {'status': 'completed', 'output': [{'type': 'function_call', 'call_id': 'call_1',
            'name': name, 'arguments': json.dumps(arguments)}]}


def reset(handler):
    """Close the connection the way a restarted proxy or server does: a reset,
    not a goodbye, so nothing the client writes on it can be delivered."""
    handler.close_connection = True
    handler.connection.setsockopt(socket.SOL_SOCKET, socket.SO_LINGER, RST)
    try:
        handler.connection.close()
    except OSError:
        pass


def last_kind(body):
    tail = body['input'][-1]
    return tail.get('type') or tail.get('role')


class API(http.server.BaseHTTPRequestHandler):
    protocol_version = 'HTTP/1.1'

    def log_message(self, *_):
        pass

    def setup(self):
        super().setup()
        state['connections'] += 1

    def finish(self):
        # The profiles close the socket themselves; flushing it again is not an
        # error.
        try:
            super().finish()
        except OSError:
            pass

    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers['Content-Length'])))
        state['requests'].append(body)
        assert self.path == '/v1/responses' and body.get('stream') is True, body
        first = len(state['requests']) == 1
        if first and state['mode'] == 'killed-after-tool':
            # The reply arrives and the connection it arrived on does not live
            # on: the request that answers this tool call is written to a dead
            # socket. The pause lets the reply be read before the reset takes
            # the receive side with it.
            send_response(self, body, call('bash', {'command': 'sleep 1'}))
            self.wfile.flush()
            time.sleep(0.25)
            reset(self)
            return
        if first and state['mode'] == 'cut-mid-answer':
            # Text has been shown, so this turn may not be sent again; the next
            # one must still have a connection to use.
            self.send_response(200)
            self.send_header('Content-Type', 'text/event-stream')
            self.send_header('Transfer-Encoding', 'chunked')
            self.end_headers()
            event = f'data: {json.dumps({"type": "response.output_text.delta", "delta": PARTIAL + chr(10)})}\n\n'.encode()
            self.wfile.write(b'%x\r\n' % len(event) + event + b'\r\n')
            self.wfile.flush()
            self.close_connection = True
            try:
                self.connection.shutdown(socket.SHUT_RDWR)
            except OSError:
                pass
            return
        send_response(self, body, completed(ANSWER))


server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), API)
threading.Thread(target=server.serve_forever, daemon=True).start()


def run(directory, lines):
    """One process, one turn per line: a connection pool is shared within a
    process, which is what makes a dead socket outlive the turn it failed."""
    env = {'PATH': '/usr/bin:/bin', 'HOME': directory, 'XDG_CONFIG_HOME': directory,
           'AI_URL': f'http://127.0.0.1:{server.server_port}/v1', 'AI_MODEL': 'mock',
           'AI_KEY': 'test'}
    trust_workspace(directory, env)
    return subprocess.run([str(binary)], cwd=directory, env=env, input=lines,
                          capture_output=True, text=True, timeout=60)


def reset_state(mode):
    state.update(mode=mode, requests=[], connections=0)


try:
    with tempfile.TemporaryDirectory(prefix='zagent-write-') as directory:
        # The keep-alive connection is killed behind a tool call. The request
        # that would reuse it fails at the write, and is sent again on a fresh
        # connection; the turn finishes as if nothing had happened, and the
        # turns after it are not poisoned by the socket that died.
        reset_state('killed-after-tool')
        result = run(directory, 'hello\nhello\n')
        assert result.returncode == 0, (result.returncode, result.stderr)
        assert 'failed to call API' not in result.stderr, result.stderr
        assert result.stdout.count(ANSWER) == 2, repr(result.stdout)
        assert state['connections'] == 2, state['connections']
        # The request whose write failed was delivered once, on the retry: a
        # write that fails is a request the server never saw.
        carried = [body for body in state['requests'] if last_kind(body) == 'function_call_output']
        assert len(carried) == 1, len(carried)

        # An answer already on the screen is never printed twice: a stream cut
        # after it started ends the turn. The next turn still gets an answer,
        # so a turn that failed does not take the session down with it.
        reset_state('cut-mid-answer')
        result = run(directory, 'hello\nhello\n')
        assert result.returncode == 0, (result.returncode, result.stderr)
        assert result.stdout.count(PARTIAL) == 1, repr(result.stdout)
        assert result.stdout.count(ANSWER) == 1, repr(result.stdout)
        assert result.stderr.count('failed to call API') == 1, result.stderr
        assert state['connections'] >= 2, state['connections']
        print('PASS: a connection killed under a request is replaced on the retry, and a '
              'turn that failed does not leave its dead socket for the next one')
finally:
    server.shutdown()
    server.server_close()
