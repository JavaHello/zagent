#!/usr/bin/env python3
"""A task must not exit successfully when its completion check rejects it."""
import http.server
import json
from pathlib import Path
import subprocess
import tempfile
import threading

binary = Path(__file__).resolve().parents[1] / 'zig-out/bin/zagent'
scenario = {'verdict': None, 'checks': 0}

class API(http.server.BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass

    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers['Content-Length'])))
        if not body.get('tools'):
            scenario['checks'] += 1
            content = scenario['verdict']
            output = [{'type': 'message', 'role': 'assistant', 'content': [{'type': 'output_text', 'text': content}]}]
            reason = 'stop'
        elif not any(m.get('type') == 'function_call_output' for m in body['input']):
            output = [{'type': 'function_call', 'call_id': 'probe', 'name': 'shell',
                       'arguments': json.dumps({'command': 'printf task-evidence'})}]
            reason = 'tool_calls'
        else:
            output = [{'type': 'message', 'role': 'assistant', 'content': [{'type': 'output_text', 'text': 'Candidate answer'}]}]
            reason = 'stop'
        assert self.path == '/v1/responses' and 'messages' not in body
        data = json.dumps({'status': 'completed', 'output': output}).encode()
        self.send_response(200)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(data)))
        self.end_headers()
        self.wfile.write(data)

server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), API)
threading.Thread(target=server.serve_forever, daemon=True).start()
try:
    with tempfile.TemporaryDirectory(prefix='zagent-completion-') as directory:
        env = {'PATH': '/usr/bin:/bin', 'HOME': directory, 'XDG_CONFIG_HOME': directory,
               'AI_URL': f'http://127.0.0.1:{server.server_port}/v1', 'AI_MODEL': 'mock',
               'AI_KEY': 'local-test', 'AI_MAX_ITERATIONS': '5', 'AI_MAX_VERIFICATIONS': '1'}
        for verdict, expected_ok in [
            (json.dumps({'complete': True, 'reason': 'Verified evidence'}), True),
            (json.dumps({'complete': False, 'reason': 'Missing behavior', 'next_step': 'Implement it'}), False),
            ('unreadable verdict', False),
        ]:
            scenario.update(verdict=verdict, checks=0)
            result = subprocess.run([str(binary), 'Perform the task'], cwd=directory, env=env,
                                    capture_output=True, text=True, timeout=30)
            assert scenario['checks'] == 1, result.stderr
            assert (result.returncode == 0) == expected_ok, result.stderr
            if not expected_ok:
                assert 'CompletionUnverified' in result.stderr, result.stderr
        print('PASS: accepted, rejected and invalid completion verdicts have correct exit status')
finally:
    server.shutdown()
