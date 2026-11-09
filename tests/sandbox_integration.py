#!/usr/bin/env python3
"""Exercise the real API -> agent -> sandbox boundary without paid API calls."""
from mock_api import send_response

import http.server
import json
import os
from pathlib import Path
import subprocess
import shutil
import tempfile
import threading

BINARY = Path(__file__).resolve().parents[1] / 'zig-out/bin/zagent'

with tempfile.TemporaryDirectory(prefix='zagent-boundary-') as temporary:
    root = Path(temporary)
    live_binary = root / 'zagent-live'
    replacement = root / 'zagent-replacement'
    shutil.copy2(BINARY, live_binary)
    shutil.copy2(BINARY, replacement)
    workspace = root / 'work'
    workspace.mkdir()
    outside = root / 'private'
    outside.write_text('SECRET_OUTSIDE_WORKSPACE_9c18')
    (workspace / 'escape').symlink_to(outside)
    forbidden = subprocess.run([str(live_binary), '--tool-worker', 'write_file',
                                json.dumps({'path': 'HOST_WORKER_BYPASS', 'content': 'must not run'})],
                               cwd=workspace, env={'PATH': '/usr/bin:/bin'}, capture_output=True,
                               text=True, timeout=10)
    assert forbidden.returncode != 0 and 'WorkerRequiresSandbox' in forbidden.stderr, forbidden.stderr
    assert not (workspace / 'HOST_WORKER_BYPASS').exists()
    calls = [
        ('shell', {'command': 'test -z "$DEEPSEEK_API_KEY" && test -z "$OPENAI_API_KEY" && test -z "$PRIVATE_SENTINEL" && echo ENV_CLEAN'}),
        ('write_file', {'path': 'notes.md', 'content': '# Report\nAnalysis complete.\n'}),
        ('apply_patch', {'patch': '--- a/notes.md\n+++ b/notes.md\n@@ -1,2 +1,2 @@\n # Report\n-Analysis complete.\n+Analysis verified.\n*** End Patch\n'}),
        ('grep', {'pattern': 'verified', 'path': '.'}),
        ('find', {'pattern': '*.md', 'path': '.'}),
        ('read_file', {'path': 'escape'}),
        ('write_file', {'path': 'escape', 'content': 'SHOULD_NOT_ESCAPE'}),
        ('read_file', {'path': str(outside)}),
        ('shell', {'command': 'cat escape; echo SHOULD_NOT_ESCAPE > escape'}),
        ('shell', {'command': "python3 -c 'import socket; socket.create_connection((\"127.0.0.1\", 1), timeout=1)'"}),
    ]
    calls.append(('shell', {'command': 'sleep 5; echo SHOULD_HAVE_TIMED_OUT', 'timeout_seconds': 1}))
    calls.extend([
        ('edit_file', {'path': 'notes.md', 'old_text': 'Analysis verified.', 'new_text': 'Analysis checked.'}),
        ('edit_file', {'path': 'notes.md', 'old_text': 'not present', 'new_text': 'MUST_NOT_APPEAR'}),
        ('edit_file', {'path': 'escape', 'old_text': 'SECRET_OUTSIDE_WORKSPACE_9c18', 'new_text': 'MUST_NOT_ESCAPE'}),
    ])
    observed = []
    requests = []

    class API(http.server.BaseHTTPRequestHandler):
        def log_message(self, *_):
            pass

        def do_POST(self):
            body = json.loads(self.rfile.read(int(self.headers['Content-Length'])))
            requests.append(body)
            if len(requests) == 1:
                os.replace(replacement, live_binary)
                self.send_response(503)
                self.send_header('Content-Length', '0')
                self.end_headers()
                return
            results = [m for m in body['input'] if m.get('type') == 'function_call_output']
            if results:
                observed.append(results[-1]['output'])
            index = len(results)
            assert self.path == '/v1/responses'
            assert 'messages' not in body and 'max_tokens' not in body and 'thinking' not in body
            assert body['store'] is False and body['max_output_tokens'] > 0
            assert 'reasoning.encrypted_content' in body['include']
            for tool in body.get('tools', []):
                assert tool['type'] == 'function' and 'function' not in tool and tool['strict'] is False
            for item in results:
                paired = [i for i in body['input'] if i.get('type') == 'function_call' and i['call_id'] == item['call_id']]
                assert len(paired) == 1 and paired[0]['id'] != item['call_id'], body
            for item in body['input']:
                if item.get('type') == 'reasoning':
                    assert item['encrypted_content'].startswith('opaque_reasoning_')
            reasoning = {'id': f'rs_{len(requests)}', 'type': 'reasoning', 'summary': [],
                         'encrypted_content': f'opaque_reasoning_{len(requests)}'}
            if index < len(calls):
                name, arguments = calls[index]
                output = [reasoning, {'id': f'fc_{len(requests)}', 'type': 'function_call',
                    'status': 'completed', 'call_id': f'call_{index}',
                    'name': name, 'arguments': json.dumps(arguments)}]
            else:
                output = [reasoning, {'id': f'msg_{len(requests)}', 'type': 'message', 'role': 'assistant',
                    'status': 'completed', 'content': [{'type': 'output_text', 'text': 'BOUNDARY_TEST_COMPLETE', 'annotations': []}]}]
            send_response(self, body, {'id': f'resp_{len(requests)}', 'object': 'response', 'status': 'completed', 'error': None, 'output': output})

    server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), API)
    calls[9] = ('shell', {'command': f"python3 -c 'import socket; socket.create_connection((\"127.0.0.1\", {server.server_port}), timeout=1)'"})
    threading.Thread(target=server.serve_forever, daemon=True).start()
    env = {'PATH': '/usr/bin:/bin', 'HOME': str(root), 'XDG_CONFIG_HOME': str(root),
           'AI_URL': f'http://127.0.0.1:{server.server_port}/v1', 'AI_MODEL': 'test-model',
           'AI_KEY': 'local-test', 'AI_MAX_VERIFICATIONS': '0', 'AI_MAX_ITERATIONS': '20',
           'AI_MEMORY': '0', 'AI_COMPACT_THRESHOLD': '0',
           'DEEPSEEK_API_KEY': 'must-not-reach-tools', 'OPENAI_API_KEY': 'must-not-reach-tools',
           'PRIVATE_SENTINEL': 'must-not-reach-tools', 'AI_SESSION_FILE': str(root / 'session.json')}
    try:
        result = subprocess.run([str(live_binary), 'Exercise the tools'], cwd=workspace, env=env,
                                text=True, capture_output=True, timeout=120)
        resumed = subprocess.run([str(live_binary), 'Continue the saved conversation'], cwd=workspace, env=env,
                                 text=True, capture_output=True, timeout=120)
        limited_env = dict(env, AI_MAX_ITERATIONS='1', AI_SESSION_FILE=str(root / 'limited.json'))
        limited = subprocess.run([str(live_binary), 'Reach the iteration limit'], cwd=workspace, env=limited_env,
                                 text=True, capture_output=True, timeout=120)
    finally:
        server.shutdown()
    assert result.returncode == 0, result.stderr
    assert result.stdout == 'BOUNDARY_TEST_COMPLETE\n', result.stderr
    assert resumed.returncode == 0, resumed.stderr
    assert len(observed) == len(calls) + 1, observed
    assert len([m for m in requests[-2]['input'] if m.get('role') == 'user']) == 2
    assert limited.returncode != 0 and 'IterationLimitReached' in limited.stderr
    snapshot = json.loads((root / 'session.json').read_text())
    assert all(m['response_items'] for m in snapshot['messages'] if m['role'] == 'assistant')
    assert any(i.get('type') == 'reasoning' for i in requests[-2]['input'])
    assert snapshot['workspace'] == os.path.realpath(str(workspace))
    assert len(snapshot['messages']) == 2 * len(calls) + 4
    assert 'ENV_CLEAN' in observed[0], observed[0]
    assert (workspace / 'notes.md').read_text() == '# Report\nAnalysis checked.\n'
    assert 'notes.md' in observed[3] and 'verified' in observed[3], observed[3]
    assert 'notes.md' in observed[4], observed[4]
    assert outside.read_text() == 'SECRET_OUTSIDE_WORKSPACE_9c18'
    assert all('SECRET_OUTSIDE_WORKSPACE_9c18' not in item for item in observed)
    assert all('Error' in observed[i] or 'stderr:' in observed[i] for i in (5, 7, 8, 9)), observed
    # Linux's private loopback returns ECONNREFUSED; macOS sandbox-exec denies
    # the connect() syscall with EPERM. Both prove the tool had no network.
    assert 'ConnectionRefusedError' in observed[9] or 'PermissionError' in observed[9], observed[9]
    assert 'Replaced one exact text block' in observed[11], observed[11]
    assert 'not found' in observed[12] and 'Error' in observed[13], observed[12:14]
    assert 'timed out' in observed[10] and 'SHOULD_HAVE_TIMED_OUT' not in observed[10], observed[10]
    print('PASS: file editing, patching, search, host isolation, symlink escape, credential isolation, network isolation, API retry, durable resume')
