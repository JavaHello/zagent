#!/usr/bin/env python3
"""Partial/failed Responses must never dispatch a function call or silently succeed."""
import http.server
import json
from pathlib import Path
import subprocess
import tempfile
import threading

binary = Path(__file__).resolve().parents[1] / 'zig-out/bin/zagent'
reply = {}
paths = []

class API(http.server.BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass

    def do_POST(self):
        paths.append(self.path)
        body = json.loads(self.rfile.read(int(self.headers['Content-Length'])))
        assert 'input' in body and 'messages' not in body
        data = json.dumps(reply).encode()
        self.send_response(200)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(data)))
        self.end_headers()
        self.wfile.write(data)

server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), API)
threading.Thread(target=server.serve_forever, daemon=True).start()
try:
    with tempfile.TemporaryDirectory(prefix='zagent-response-status-') as directory:
        call = {'id': 'fc_unsafe', 'type': 'function_call', 'call_id': 'call_unsafe', 'name': 'write_file',
                'arguments': json.dumps({'path': 'MUST_NOT_EXIST', 'content': 'unsafe partial response'})}
        cases = [
            ({'status': 'incomplete', 'incomplete_details': {'reason': 'max_output_tokens'}, 'output': [call]}, 'ResponseTruncated'),
            ({'status': 'completed', 'output': [dict(call, status='in_progress')]}, 'ResponseNotCompleted'),
            ({'status': 'failed', 'error': {'message': 'provider inference failed'}}, 'provider inference failed'),
            ({'status': 'queued', 'output': [call]}, 'ResponseNotCompleted'),
            ({'status': 'completed', 'output': []}, 'EmptyResponse'),
            ({'choices': [{'message': {'content': 'legacy response'}}]}, 'InvalidResponse'),
        ]
        env = {'PATH': '/usr/bin:/bin', 'HOME': directory, 'XDG_CONFIG_HOME': directory,
               'AI_URL': f'http://127.0.0.1:{server.server_port}/v1/', 'AI_MODEL': 'test-model',
               'AI_KEY': 'local-test', 'AI_MAX_VERIFICATIONS': '0'}
        for response, expected_error in cases:
            reply.clear()
            reply.update(response)
            result = subprocess.run([str(binary), 'Perform the task'], cwd=directory, env=env,
                                    capture_output=True, text=True, timeout=15)
            assert result.returncode != 0 and expected_error in result.stderr, result.stderr
            assert not (Path(directory) / 'MUST_NOT_EXIST').exists(), 'Incomplete function call executed'
        assert paths == ['/v1/responses'] * len(cases), paths
        print('PASS: incomplete/failed/pending/malformed Responses fail without executing tools or protocol fallback')
finally:
    server.shutdown()
