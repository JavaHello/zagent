#!/usr/bin/env python3
"""The main model settles turns; completion never sends a judge request."""
from mock_api import send_response, trust_workspace
import http.server
import json
from pathlib import Path
import subprocess
import tempfile
import threading

binary = Path(__file__).resolve().parents[1] / 'zig-out/bin/zagent'
scenario = {}

class API(http.server.BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass

    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers['Content-Length'])))
        scenario['requests'] += 1
        if not body.get('tools'):
            scenario['checks'] += 1
        assert self.path == '/v1/responses'
        instructions = json.dumps([m for m in body['input']
                                   if m.get('role') in ('system', 'developer')])
        assert 'You are zagent' in instructions, instructions
        assert '[task_status:' not in instructions, instructions
        calls = [m for m in body['input'] if m.get('type') == 'function_call_output']
        commands = []
        if scenario['work']:
            commands.append(('probe', 'bash', {'command': 'printf task-evidence'}))
        if len(calls) < len(commands):
            call_id, name, args = commands[len(calls)]
            output = [{'type': 'function_call', 'call_id': call_id,
                       'name': name, 'arguments': json.dumps(args)}]
        else:
            output = [{'type': 'message', 'role': 'assistant', 'content': [
                {'type': 'output_text', 'text': scenario['answer']}]}]
        send_response(self, body, {'status': 'completed', 'output': output})

server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), API)
threading.Thread(target=server.serve_forever, daemon=True).start()
try:
    with tempfile.TemporaryDirectory(prefix='zagent-completion-') as directory:
        env = {'PATH': '/usr/bin:/bin', 'HOME': directory, 'XDG_CONFIG_HOME': directory,
               'AI_URL': f'http://127.0.0.1:{server.server_port}/v1', 'AI_MODEL': 'mock',
               'AI_KEY': 'local-test', 'AI_MAX_ITERATIONS': '8'}
        trust_workspace(directory, env)
        cases = [
            'The work is done and validated.',
            'Blocked: credentials are missing. Please configure authentication.',
            'The command failed; no changes were made.',
            'Which deployment target should I use?',
            'Partial work saved; resume after the dependency is available.',
            # Legacy or quoted markers are ordinary answer text, not a protocol.
            '[task_status: blocked]',
            '[task_status: unknown]',
            '[task_status: completed]\nStill working',
            'Quoted [task_status: completed]',
        ]
        for work in (False, True):
            for answer in cases:
                scenario.update(work=work, checks=0, requests=0, answer=answer)
                result = subprocess.run([str(binary), 'Perform the task'], cwd=directory,
                                        env=env, capture_output=True, text=True, timeout=30)
                assert result.returncode == 0, result.stderr
                assert scenario['checks'] == 0, result.stderr
                assert scenario['requests'] == (2 if work else 1), scenario
                assert answer in result.stdout, result.stdout
                assert 'Turn finished' in result.stderr, result.stderr
                for obsolete in ('Task completed', 'Task blocked', 'Task failed',
                                 'Task awaiting user input', 'Task paused'):
                    assert obsolete not in result.stderr, result.stderr
finally:
    server.shutdown()
print('main-model completion integration passed')
