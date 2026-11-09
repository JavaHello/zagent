#!/usr/bin/env python3
"""Partial/failed Responses must never dispatch a function call or silently succeed."""
from mock_api import send_response

import http.server
import json
from pathlib import Path
import subprocess
import tempfile
import threading

binary = Path(__file__).resolve().parents[1] / 'zig-out/bin/zagent'
reply = {}
paths = []
requests = []
replies = []

class API(http.server.BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass

    def do_POST(self):
        paths.append(self.path)
        body = json.loads(self.rfile.read(int(self.headers['Content-Length'])))
        requests.append(body)
        assert 'input' in body and 'messages' not in body
        send_response(self, body, replies.pop(0) if replies else reply)

server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), API)
threading.Thread(target=server.serve_forever, daemon=True).start()
try:
    with tempfile.TemporaryDirectory(prefix='zagent-response-status-') as directory:
        call = {'id': 'fc_unsafe', 'type': 'function_call', 'call_id': 'call_unsafe', 'name': 'write_file',
                'arguments': json.dumps({'path': 'MUST_NOT_EXIST', 'content': 'unsafe partial response'})}
        cases = [
            ({'status': 'incomplete', 'incomplete_details': {'reason': 'max_output_tokens'}, 'output': [call]}, 'ResponseTruncated'),
            ({'status': 'incomplete', 'incomplete_details': {'reason': 'content_filter'}, 'output': [call]}, 'ResponseNotCompleted'),
            ({'status': 'incomplete', 'output': [call]}, 'ResponseNotCompleted'),
            ({'status': 'completed', 'output': [dict(call, status='in_progress')]}, 'ResponseNotCompleted'),
            ({'status': 'failed', 'error': {'message': 'provider inference failed'}}, 'provider inference failed'),
            ({'status': 'queued', 'output': [call]}, 'ResponseNotCompleted'),
            ({'status': 'completed', 'output': []}, 'EmptyResponse'),
            ({'choices': [{'message': {'content': 'legacy response'}}]}, 'InvalidResponse'),
            # Even a valid first call must not run when a later item makes the
            # response invalid: dispatch waits for validation of the full batch.
            ({'status': 'completed', 'output': [call, dict(call)]}, 'DuplicateCallId'),
            ({'status': 'completed', 'output': [call, dict(call, call_id='')]}, 'InvalidResponse'),
            ({'status': 'completed', 'output': [call, dict(call, call_id='other', name='')]}, 'InvalidResponse'),
            ({'status': 'completed', 'output': [call, dict(call, call_id='other', arguments={})]}, 'InvalidResponse'),
            ({'status': 'completed', 'output': [call, {'type': 'message', 'role': 'user', 'content': []}]}, 'InvalidResponse'),
            ({'status': 'completed', 'output': [call, {'type': 'unknown'}]}, 'UnsupportedOutputItem'),
        ]
        env = {'PATH': '/usr/bin:/bin', 'HOME': directory, 'XDG_CONFIG_HOME': directory,
               'AI_URL': f'http://127.0.0.1:{server.server_port}/v1/', 'AI_MODEL': 'test-model',
               'AI_KEY': 'local-test', 'AI_MAX_VERIFICATIONS': '0',
               'AI_MEMORY': '0', 'AI_COMPACT_THRESHOLD': '0'}
        for response, expected_error in cases:
            requests.clear()
            reply.clear()
            reply.update(response)
            result = subprocess.run([str(binary), 'Perform the task'], cwd=directory, env=env,
                                    capture_output=True, text=True, timeout=15)
            assert result.returncode != 0 and expected_error in result.stderr, result.stderr
            assert not (Path(directory) / 'MUST_NOT_EXIST').exists(), 'Incomplete function call executed'
            # The default budget already sits on the growth cap, so a truncated
            # response is not retried with a larger budget. It is asked for a
            # smaller step twice before the turn is given up.
            expected_budgets = [8192, 8192, 8192] if expected_error == 'ResponseTruncated' else [8192]
            assert [r['max_output_tokens'] for r in requests] == expected_budgets, requests

        # Recover after a completed tool without losing its result or replaying
        # its execution. The completion judge uses the same recovery path.
        (Path(directory) / 'evidence.txt').write_text('retained-tool-evidence')
        def completed_text(text):
            return {'status': 'completed', 'output': [{'type': 'message', 'role': 'assistant',
                    'content': [{'type': 'output_text', 'text': text}]}]}

        def incomplete_text(text):
            return {'status': 'incomplete', 'incomplete_details': {'reason': 'max_output_tokens'},
                    'output': [{'type': 'message', 'role': 'assistant', 'status': 'incomplete',
                                'content': [{'type': 'output_text', 'text': text}]}]}

        # A reply cut short mid-answer is continued, not thrown away: the
        # partial text is kept and the model is asked to carry on from it.
        replies.extend([incomplete_text('Half an answer. '), completed_text('The rest.')])
        requests.clear()
        result = subprocess.run([str(binary), 'Perform the task'], cwd=directory, env=env,
                                capture_output=True, text=True, timeout=15)
        assert result.returncode == 0, result.stderr
        assert 'Half an answer. The rest.' in result.stdout, result.stdout
        assert [r['max_output_tokens'] for r in requests] == [8192, 8192], requests
        continued = requests[1]['input']
        assert any(item.get('role') == 'assistant' and 'Half an answer.' in str(item.get('content'))
                   for item in continued), continued
        assert any(item.get('role') == 'user' and 'Continue exactly where it stopped' in str(item.get('content'))
                   for item in continued), continued

        # A call too large for the budget leaves no text to continue. The model
        # is asked instead to retry in smaller steps, and the partial call is
        # still never executed.
        partial = cases[0][0]
        replies.extend([partial, completed_text('Split into chunks.')])
        requests.clear()
        result = subprocess.run([str(binary), 'Perform the task'], cwd=directory, env=env,
                                capture_output=True, text=True, timeout=15)
        assert result.returncode == 0, result.stderr
        assert 'Split into chunks.' in result.stdout, result.stdout
        assert [r['max_output_tokens'] for r in requests] == [8192, 8192], requests
        assert any(item.get('role') == 'user' and 'Try again in smaller steps' in str(item.get('content'))
                   for item in requests[1]['input']), requests[1]
        assert not (Path(directory) / 'MUST_NOT_EXIST').exists(), 'Incomplete function call executed'

        replies.extend([
            {'status': 'completed', 'output': [{'type': 'function_call', 'call_id': 'read_evidence',
                'name': 'read_file', 'arguments': json.dumps({'path': 'evidence.txt'})}]},
            partial, partial, completed_text('Recovered answer'),
            partial, completed_text(json.dumps({'complete': True, 'reason': 'Verified evidence'})),
        ])
        requests.clear()
        # Growth is only possible from below the cap, so this case lowers the
        # budget to exercise the doubling up to the DeepSeek ceiling.
        result = subprocess.run([str(binary), 'Perform the task'], cwd=directory,
                                env=dict(env, AI_MAX_VERIFICATIONS='1', AI_MAX_TOKENS='2048'),
                                capture_output=True, text=True, timeout=15)
        assert result.returncode == 0 and 'Recovered answer' in result.stdout, result.stderr
        assert not replies, replies
        assert [r['max_output_tokens'] for r in requests] == [2048, 2048, 4096, 8192, 2048, 4096]
        assert requests[1]['input'] == requests[2]['input'] == requests[3]['input']
        assert any(item.get('type') == 'function_call_output' and 'retained-tool-evidence' in item['output']
                   for item in requests[1]['input']), requests[1]
        assert requests[4]['input'] == requests[5]['input']
        assert 'tools' not in requests[4] and 'tools' not in requests[5]
        assert not (Path(directory) / 'MUST_NOT_EXIST').exists(), 'Incomplete function call executed'

        # The growth cap must not loop or lower a larger configured budget.
        # With no text to continue, each of the three attempts is given the
        # configured budget (doubled only while below the 8192 ceiling).
        for budget, expected in [(4096, [4096, 8192] * 3), (8192, [8192] * 3),
                                 (65536, [65536] * 3), (200000, [200000] * 3)]:
            reply.clear()
            reply.update(partial)
            requests.clear()
            result = subprocess.run([str(binary), 'Perform the task'], cwd=directory,
                                    env=dict(env, AI_MAX_TOKENS=str(budget)),
                                    capture_output=True, text=True, timeout=15)
            assert result.returncode != 0 and 'ResponseTruncated' in result.stderr, result.stderr
            assert [r['max_output_tokens'] for r in requests] == expected, requests
        assert all(path == '/v1/responses' for path in paths), paths
        print('PASS: bounded truncation recovery preserves tool results; partial calls never execute')
finally:
    server.shutdown()
