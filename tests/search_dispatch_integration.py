#!/usr/bin/env python3
"""Each search tool runs the program it names, and a missing one is never swapped."""
import http.server
import json
import subprocess
import tempfile
import threading
from pathlib import Path

from mock_api import send_response, trust_workspace

BINARY = Path(__file__).resolve().parents[1] / 'zig-out/bin/zagent'


def tool_output(output):
    header, separator, content = output.partition('\n')
    assert separator and header.startswith('[tool_status ') and header.endswith(']'), output
    return json.loads(header[len('[tool_status '):-1]), content


def exercise(root, workspace, executables, names):
    """Ask the model to call `names` in order and return what each one answered."""
    calls = [(name, json.dumps({'pattern': 'needle', 'path': '.'})) for name in names]
    observed = []
    requests = []

    class API(http.server.BaseHTTPRequestHandler):
        def log_message(self, *_):
            pass

        def do_POST(self):
            body = json.loads(self.rfile.read(int(self.headers['Content-Length'])))
            requests.append(body)
            results = [m for m in body['input'] if m.get('type') == 'function_call_output']
            if results:
                observed.append(results[-1]['output'])
            index = len(results)
            if index < len(calls):
                name, arguments = calls[index]
                output = [{'id': f'fc_{index}', 'type': 'function_call', 'status': 'completed',
                           'call_id': f'call_{index}', 'name': name, 'arguments': arguments}]
            else:
                output = [{'id': 'msg', 'type': 'message', 'role': 'assistant',
                           'status': 'completed', 'content': [
                               {'type': 'output_text', 'text': 'SEARCH_DONE', 'annotations': []}]}]
            send_response(self, body, {'id': 'resp', 'object': 'response', 'status': 'completed',
                                      'error': None, 'output': output})

    server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), API)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    env = {'PATH': str(executables), 'HOME': str(root), 'XDG_CONFIG_HOME': str(root),
           'AI_URL': f'http://127.0.0.1:{server.server_port}/v1', 'AI_MODEL': 'test-model',
           'AI_KEY': 'local-test', 'AI_MAX_ITERATIONS': '20'}
    trust_workspace(workspace, env)
    try:
        result = subprocess.run([str(BINARY), 'Search the workspace'], cwd=workspace, env=env,
                                text=True, capture_output=True, timeout=120)
    finally:
        server.shutdown()
        server.server_close()
    assert result.returncode == 0, result.stderr
    assert result.stdout == 'SEARCH_DONE\n', (result.stdout, result.stderr)
    assert len(observed) == len(calls), (len(observed), result.stderr)
    return [tool_output(output) for output in observed]


# Every search tool runs the program its name stands for, whichever others are
# installed: the fake programs here answer with their own name and nothing else.
with tempfile.TemporaryDirectory(prefix='zagent-search-dispatch-') as directory:
    root = Path(directory)
    workspace = root / 'work'
    workspace.mkdir()
    installed = {}
    for name in ('rg', 'grep', 'fd', 'find'):
        program = root / name
        program.write_text(f'#!/bin/sh\nprintf "{name}-only\\n"\n')
        program.chmod(0o755)
        installed[name] = program

    # All four present: each name reaches its own program.
    statuses, contents = zip(*exercise(root, workspace, root, ('rg', 'grep', 'fd', 'find')))
    for name, status, content in zip(('rg', 'grep', 'fd', 'find'), statuses, contents):
        assert not status['is_error'], (name, status, content)
        assert content.strip() == f'{name}-only', (name, content)

    # With rg and fd gone, each tool reports that its own program is missing
    # rather than answering with the one that is installed.
    for name in ('rg', 'grep', 'fd', 'find'):
        installed[name].unlink()
    for name in ('rg', 'fd'):
        installed[name].write_text(f'#!/bin/sh\nprintf "{name}-only\\n"\n')
        installed[name].chmod(0o755)
    statuses, contents = zip(*exercise(root, workspace, root, ('grep', 'find')))
    for name, status, content in zip(('grep', 'find'), statuses, contents):
        assert status['is_error'], (name, status, content)
        assert f"could not run '{name}'" in content, (name, content)
        for other in ('rg', 'fd'):
            assert f'{other}-only' not in content, (name, other, content)

print('PASS: search tools run only the program they name, and report a missing one')
