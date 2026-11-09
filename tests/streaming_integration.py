#!/usr/bin/env python3
"""Streamed output must preserve raw text and its final newline when piped."""
import http.server
import json
from pathlib import Path
import subprocess
import tempfile
import threading

from mock_api import send_response, handle_planning, PLAN_APPROACH

binary = Path(__file__).resolve().parents[1] / 'zig-out/bin/zagent'
answer = ''


class API(http.server.BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass

    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers['Content-Length'])))
        if handle_planning(self, body):
            return
        assert body['stream'] is True
        assert self.path == '/v1/responses'
        send_response(self, body, {'status': 'completed', 'output': [
            {'type': 'message', 'role': 'assistant',
             'content': [{'type': 'output_text', 'text': answer}]}]})


server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), API)
threading.Thread(target=server.serve_forever, daemon=True).start()
try:
    with tempfile.TemporaryDirectory(prefix='zagent-stream-') as directory:
        env = {'PATH': '/usr/bin:/bin', 'HOME': directory, 'XDG_CONFIG_HOME': directory,
               'AI_URL': f'http://127.0.0.1:{server.server_port}/v1', 'AI_KEY': 'test',
               'AI_MODEL': 'mock', 'AI_MAX_VERIFICATIONS': '0', 'AI_MEMORY': '0',
               'AI_COMPACT_THRESHOLD': '0'}
        for answer in ('Plain answer', '中文与 emoji 😀', '# Heading\n\n**bold**\n',
                       'first\nsecond', '```zig\nconst n = 1;\n```'):
            result = subprocess.run([str(binary), 'Answer'], cwd=directory, env=env,
                                    capture_output=True, text=True, timeout=15)
            assert result.returncode == 0, result.stderr
            assert result.stdout == PLAN_APPROACH + '\n\n' + answer + '\n', repr(result.stdout)
        print('PASS: streamed plain text, Unicode, multiline markdown, fences and trailing newlines')
finally:
    server.shutdown()
    server.server_close()
