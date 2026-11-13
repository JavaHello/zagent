#!/usr/bin/env python3
"""A request the network broke is sent again, unless the answer already started."""
import http.server
import json
import socket
from pathlib import Path
import subprocess
import tempfile
import threading

from mock_api import send_response, trust_workspace

binary = Path(__file__).resolve().parents[1] / 'zig-out/bin/zagent'
requests = []
profile = {'mode': 'close-before-reply', 'dropped': False}
ANSWER = 'recovered answer'
PARTIAL = 'half an answer'


def completed(text):
    return {'status': 'completed', 'output': [{'type': 'message', 'role': 'assistant',
            'content': [{'type': 'output_text', 'text': text}]}]}


def drop(handler):
    """Close the connection the way a restarted proxy or server does."""
    handler.close_connection = True
    try:
        handler.connection.shutdown(socket.SHUT_RDWR)
    except OSError:
        pass
    handler.connection.close()


class API(http.server.BaseHTTPRequestHandler):
    protocol_version = 'HTTP/1.1'

    def log_message(self, *_):
        pass

    def finish(self):
        # The profile closes the socket itself; flushing it again is not an error.
        try:
            super().finish()
        except OSError:
            pass

    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers['Content-Length'])))
        requests.append(body)
        assert self.path == '/v1/responses' and body.get('stream') is True, body
        if not profile['dropped']:
            profile['dropped'] = True
            if profile['mode'] == 'close-before-reply':
                # The request was read and the connection went away without a
                # reply: nothing of the answer ever reached the client.
                drop(self)
                return
            # The answer starts and the stream is then cut, so it has already
            # been shown once and must not be shown twice.
            self.send_response(200)
            self.send_header('Content-Type', 'text/event-stream')
            self.send_header('Transfer-Encoding', 'chunked')
            self.end_headers()
            event = f'data: {json.dumps({"type": "response.output_text.delta", "delta": PARTIAL + chr(10)})}\n\n'.encode()
            self.wfile.write(b'%x\r\n' % len(event) + event + b'\r\n')
            self.wfile.flush()
            drop(self)
            return
        send_response(self, body, completed(ANSWER))


server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), API)
threading.Thread(target=server.serve_forever, daemon=True).start()
try:
    with tempfile.TemporaryDirectory(prefix='zagent-retry-') as directory:
        env = {'PATH': '/usr/bin:/bin', 'HOME': directory, 'XDG_CONFIG_HOME': directory,
               'AI_URL': f'http://127.0.0.1:{server.server_port}/v1', 'AI_MODEL': 'mock',
               'AI_KEY': 'test'}
        trust_workspace(directory, env)

        # A connection closed before the reply is sent again, and the turn
        # finishes as if nothing had happened.
        result = subprocess.run([str(binary), 'Answer'], cwd=directory, env=env,
                                capture_output=True, text=True, timeout=30)
        assert result.returncode == 0, (result.returncode, result.stderr)
        assert result.stdout == ANSWER + '\n', repr(result.stdout)
        assert len(requests) == 2, len(requests)
        assert 'failed to call API' not in result.stderr, result.stderr
        # The retry is the same request on a new connection, not a new turn.
        assert requests[0] == requests[1], requests

        # A stream cut after the answer started ends the turn instead: the text
        # is already on the screen, so a retry would print it a second time.
        requests.clear()
        profile.update(mode='close-mid-answer', dropped=False)
        result = subprocess.run([str(binary), 'Answer'], cwd=directory, env=env,
                                capture_output=True, text=True, timeout=30)
        assert result.returncode != 0, result.stdout
        assert len(requests) == 1, len(requests)
        assert PARTIAL in result.stdout, repr(result.stdout)
        assert ANSWER not in result.stdout, result.stdout
        assert 'failed to call API' in result.stderr, result.stderr
        print('PASS: a closed connection is retried with the same request; a stream cut after '
              'text was shown ends the turn without repeating it')
finally:
    server.shutdown()
    server.server_close()
