#!/usr/bin/env python3
"""Exercise the real API -> agent -> sandbox boundary without paid API calls."""
from mock_api import send_response, handle_planning, PLAN_APPROACH

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
    forbidden = subprocess.run([str(live_binary), '--direct-tool-worker', 'write_file',
                                json.dumps({'path': '/etc/zagent-policy-test-must-not-exist', 'content': 'must not run'})],
                               cwd=workspace, env={'PATH': '/usr/bin:/bin'}, capture_output=True,
                               text=True, timeout=10)
    assert forbidden.returncode != 0 and 'WorkerRequiresSandbox' in forbidden.stderr, forbidden.stderr
    assert not (workspace / 'HOST_WORKER_BYPASS').exists()
    calls = [
        ('shell', {'command': 'test -n "$DEEPSEEK_API_KEY" && test -n "$OPENAI_API_KEY" && test -n "$PRIVATE_SENTINEL" && echo ENV_INHERITED'}),
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
        ('edit_file', {'path': 'escape', 'old_text': 'SHOULD_NOT_ESCAPE', 'new_text': 'DIRECT_EDIT_WORKED'}),
        ('shell', {'command': 'echo DANGEROUS_HOST_WRITE > /etc/zagent-policy-test-must-not-exist && echo SANDBOX_PRIVATE_WRITE'}),
    ])
    observed = []
    requests = []

    class API(http.server.BaseHTTPRequestHandler):
        def log_message(self, *_):
            pass

        def do_POST(self):
            body = json.loads(self.rfile.read(int(self.headers['Content-Length'])))
            if handle_planning(self, body):
                return
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
    assert result.stdout == PLAN_APPROACH + '\n\nBOUNDARY_TEST_COMPLETE\n', result.stderr
    assert resumed.returncode == 0, resumed.stderr
    assert len(observed) == len(calls) + 1, observed
    assert len([m for m in requests[-2]['input'] if m.get('role') == 'user']) == 2
    assert limited.returncode != 0 and 'IterationLimitReached' in limited.stderr
    snapshot = json.loads((root / 'session.json').read_text())
    # The preflight stores its public approach as a plain assistant message;
    # execution responses must still retain their exact replay items.
    assert all(m['response_items'] for m in snapshot['messages']
               if m['role'] == 'assistant' and m['content'] != PLAN_APPROACH)
    assert any(i.get('type') == 'reasoning' for i in requests[-2]['input'])
    assert snapshot['workspace'] == os.path.realpath(str(workspace))
    assert len(snapshot['messages']) == 2 * len(calls) + 6
    assert 'ENV_INHERITED' in observed[0], observed[0]
    assert (workspace / 'notes.md').read_text() == '# Report\nAnalysis checked.\n'
    assert 'notes.md' in observed[3] and 'verified' in observed[3], observed[3]
    assert 'notes.md' in observed[4], observed[4]
    assert outside.read_text() == 'DIRECT_EDIT_WORKED\n', (outside.read_text(), observed[6:14])
    assert 'SECRET_OUTSIDE_WORKSPACE_9c18' in observed[5]
    assert not Path('/etc/zagent-policy-test-must-not-exist').exists()
    # Linux exposes a private /etc directory: a write there may succeed, but
    # must never reach the host. Other sandbox backends may deny it outright.
    assert ('SANDBOX_PRIVATE_WRITE' in observed[14] or
            'stderr:' in observed[14] or 'failed' in observed[14].lower()), observed[14]
    assert 'Replaced one exact text block' in observed[11], observed[11]
    assert 'not found' in observed[12] and 'Replaced one exact text block' in observed[13], observed[12:14]
    assert 'timed out' in observed[10] and 'SHOULD_HAVE_TIMED_OUT' not in observed[10], observed[10]
    assert observed[9] == '(no output)', observed[9]
    # Exercise disabled sandbox policy through the real CLI/worker boundary.
    calls[:] = [
        ('bash', {'command': 'items=(hello world); [[ ${#items[@]} == 2 ]] && printf "%s" "${items[1]}"'}),
        ('shell', {'command': 'echo LEGACY_ALIAS'}),
        ('bash', {'command': 'echo MUST_NOT_RUN > /etc/zagent-policy-test-must-not-exist'}),
    ]
    observed.clear()
    requests.clear()
    shutil.copy2(live_binary, replacement)
    config_dir = root / 'zagent'
    config_dir.mkdir()
    (config_dir / 'mcp.json').write_text(json.dumps({'mcpServers': {
        'disabled-local': {'command': 'sh', 'args': ['-c', 'touch MCP_MUST_NOT_START']}
    }}))
    server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), API)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    off_env = dict(env, AI_TOOL_SANDBOX='off', AI_URL=f'http://127.0.0.1:{server.server_port}/v1',
                   AI_SESSION_FILE=str(root / 'off-session.json'))
    try:
        off = subprocess.run([str(live_binary), 'Exercise disabled sandbox'], cwd=workspace,
                             env=off_env, text=True, capture_output=True, timeout=60)
    finally:
        server.shutdown()
    assert off.returncode == 0, off.stderr
    assert observed[:2] == ['world', 'LEGACY_ALIAS\n'], observed
    assert 'requires isolation and was not executed' in observed[2], observed
    assert 'skipped local MCP server' in off.stderr, off.stderr
    assert not (workspace / 'MCP_MUST_NOT_START').exists()
    assert not Path('/etc/zagent-policy-test-must-not-exist').exists()
    tool_names = [t['name'] for t in requests[0]['tools']]
    assert 'bash' in tool_names and 'shell' not in tool_names, tool_names
    print('PASS: direct editing/search, host environment/network, dangerous-command isolation, timeout, API retry, durable resume, Bash/legacy alias, sandbox off and local MCP skip')
