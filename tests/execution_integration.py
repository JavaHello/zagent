#!/usr/bin/env python3
"""Exercise real API -> agent -> host tool execution without paid API calls."""
from mock_api import send_response, handle_planning, PLAN_APPROACH, trust_workspace

import http.server
import json
import os
from pathlib import Path
import subprocess
import shutil
import tempfile
import threading

BINARY = Path(__file__).resolve().parents[1] / 'zig-out/bin/zagent'


def tool_output(output):
    header, separator, content = output.partition('\n')
    assert separator and header.startswith('[tool_status ') and header.endswith(']'), output
    status = json.loads(header[len('[tool_status '):-1])
    assert set(status) == {'is_error', 'exit_code', 'timed_out', 'truncated'}, status
    return status, content


# Keep fixture paths short and stable across POSIX hosts.
with tempfile.TemporaryDirectory(prefix='zagent-boundary-', dir='/tmp') as temporary:
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
    worker = subprocess.run([str(live_binary), '--tool-worker', 'bash',
                             json.dumps({'command': '/bin/echo HOST_WORKER'})],
                            cwd=workspace, env={'PATH': '/usr/bin:/bin'}, capture_output=True,
                            text=True, timeout=10)
    assert worker.returncode == 0, worker.stderr
    assert 'HOST_WORKER' in json.loads(worker.stdout)['content'], worker.stdout
    calls = [
        ('bash', {'command': 'test -n "$DEEPSEEK_API_KEY" && test -n "$OPENAI_API_KEY" && test -n "$PRIVATE_SENTINEL" && echo ENV_INHERITED'}),
        ('write', {'path': 'notes.md', 'content': '# Report\nAnalysis complete.\n'}),
        ('apply_patch', {'patch': '--- a/notes.md\n+++ b/notes.md\n@@ -1,2 +1,2 @@\n # Report\n-Analysis complete.\n+Analysis verified.\n*** End Patch\n'}),
        ('grep', {'pattern': 'verified', 'path': '.'}),
        ('find', {'pattern': '*.md', 'path': '.'}),
        ('read', {'path': 'escape'}),
        ('write', {'path': 'escape', 'content': 'SHOULD_NOT_ESCAPE'}),
        ('read', {'path': str(outside)}),
        ('bash', {'command': 'cat escape; echo SHOULD_NOT_ESCAPE > escape'}),
        ('bash', {'command': "python3 -c 'import socket; socket.create_connection((\"127.0.0.1\", 1), timeout=1)'"}),
    ]
    calls.append(('bash', {'command': 'sleep 5; echo SHOULD_HAVE_TIMED_OUT', 'timeout_seconds': 1}))
    calls.extend([
        ('write', {'path': 'notes.md', 'old_text': 'Analysis verified.', 'new_text': 'Analysis checked.'}),
        ('write', {'path': 'notes.md', 'old_text': 'not present', 'new_text': 'MUST_NOT_APPEAR'}),
        ('write', {'path': 'escape', 'old_text': 'SHOULD_NOT_ESCAPE', 'new_text': 'DIRECT_EDIT_WORKED'}),
        ('bash', {'command': '/bin/echo HOST_WRITE > host-write.txt && cat host-write.txt'}),
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
    calls[9] = ('bash', {'command': f"python3 -c 'import socket; socket.create_connection((\"127.0.0.1\", {server.server_port}), timeout=1)'"})
    threading.Thread(target=server.serve_forever, daemon=True).start()
    env = {'PATH': '/usr/bin:/bin', 'HOME': str(root), 'XDG_CONFIG_HOME': str(root),
           'AI_URL': f'http://127.0.0.1:{server.server_port}/v1', 'AI_MODEL': 'test-model',
           'AI_KEY': 'local-test', 'AI_MAX_ITERATIONS': '20',
           'DEEPSEEK_API_KEY': 'must-not-reach-tools', 'OPENAI_API_KEY': 'must-not-reach-tools',
           'PRIVATE_SENTINEL': 'must-not-reach-tools'}
    state = trust_workspace(workspace, env)
    try:
        result = subprocess.run([str(live_binary), 'Exercise the tools'], cwd=workspace, env=env,
                                text=True, capture_output=True, timeout=120)
        session_path, = (state / 'sessions').glob('*.json')
        resumed = subprocess.run([str(live_binary), '--resume', session_path.stem,
                                  'Continue the saved conversation'], cwd=workspace, env=env,
                                 text=True, capture_output=True, timeout=120)
        limited_env = dict(env, AI_MAX_ITERATIONS='1')
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
    snapshot = json.loads(session_path.read_text())
    statuses, contents = zip(*(tool_output(output) for output in observed))
    observed[:] = contents
    saved_statuses = [m['tool_status'] for m in snapshot['messages'] if m['role'] == 'tool']
    assert saved_statuses == list(statuses[:len(calls)]), (saved_statuses, statuses)
    resumed_statuses = [tool_output(m['output'])[0] for m in requests[-2]['input']
                       if m.get('type') == 'function_call_output']
    assert resumed_statuses == saved_statuses, (resumed_statuses, saved_statuses)
    assert statuses[10]['is_error'] and statuses[10]['timed_out'], statuses[10]
    assert statuses[9] == {'is_error': False, 'exit_code': 0,
                           'timed_out': False, 'truncated': False}, statuses[9]
    assert statuses[12]['is_error'], statuses[12]
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
    assert statuses[14]['exit_code'] == 0 and not statuses[14]['is_error'], statuses[14]
    assert (workspace / 'host-write.txt').read_text() == 'HOST_WRITE\n'
    assert 'HOST_WRITE' in observed[14], observed[14]
    assert 'Replaced one exact text block' in observed[11], observed[11]
    assert 'not found' in observed[12] and 'Replaced one exact text block' in observed[13], observed[12:14]
    assert 'timed out' in observed[10] and 'SHOULD_HAVE_TIMED_OUT' not in observed[10], observed[10]
    assert observed[9] == 'Exit code: 0\n(no output)', observed[9]
    # Host tools and local MCP startup need no isolation configuration.
    calls[:] = [
        ('bash', {'command': 'items=(hello world); [[ ${#items[@]} == 2 ]] && printf "%s" "${items[1]}"'}),
        ('bash', {'command': 'echo BASH_ONLY'}),
        ('bash', {'command': '/bin/echo HOST_EXECUTION'}),
    ]
    observed.clear()
    requests.clear()
    shutil.copy2(live_binary, replacement)
    config_dir = root / 'zagent'
    config_dir.mkdir()
    (config_dir / 'mcp.json').write_text(json.dumps({'mcpServers': {
        'host-local': {'command': 'sh', 'args': ['-c', 'printf "%s" "$PRIVATE_SENTINEL" > MCP_STARTED']}
    }}))
    server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), API)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    host_env = dict(env, AI_URL=f'http://127.0.0.1:{server.server_port}/v1')
    try:
        host = subprocess.run([str(live_binary), 'Exercise host execution'], cwd=workspace,
                              env=host_env, text=True, capture_output=True, timeout=60)
    finally:
        server.shutdown()
    assert host.returncode == 0, host.stderr
    host_statuses, host_contents = zip(*(tool_output(output) for output in observed))
    observed[:] = host_contents
    assert all(s['exit_code'] == 0 and not s['is_error'] for s in host_statuses[:2]), host_statuses
    assert not host_statuses[2]['is_error'] and host_statuses[2]['exit_code'] == 0, host_statuses[2]
    assert observed[:2] == ['Exit code: 0\nworld', 'Exit code: 0\nBASH_ONLY\n'], observed
    assert 'HOST_EXECUTION' in observed[2], observed
    assert (workspace / 'MCP_STARTED').read_text() == env['PRIVATE_SENTINEL']
    tool_names = [t['name'] for t in requests[0]['tools']]
    assert 'bash' in tool_names and 'shell' not in tool_names, tool_names
    print('PASS: direct editing/search, host environment/network, timeout, API retry, durable resume, Bash and local MCP startup')
