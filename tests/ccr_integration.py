#!/usr/bin/env python3
"""Real worker output is cached per agent, retrievable, and cleared by /new."""
import http.server
import json
from pathlib import Path
import re
import subprocess
import tempfile
import threading

from mock_api import send_response, trust_workspace

BINARY = Path(__file__).resolve().parents[1] / 'zig-out/bin/zagent'
COMMAND = "python3 -c 'for i in range(20000): print(\"ROW-%05d payload\" % i)'"
EXPECTED = ''.join(f'ROW-{i:05d} payload\n' for i in range(20000))
ids = {}
paths = {}
errors = []
seen = []


def unpack(output):
    header, content = output.split('\n', 1)
    assert header.startswith('[tool_status ') and header.endswith(']'), output
    return json.loads(header[len('[tool_status '):-1]), content


def cached(output, path):
    status, content = unpack(output)
    assert not status['is_error'] and status['exit_code'] == 0, output
    assert status['truncated'], status
    assert 'ROW-19999 payload' in content and 'ROW-00000 payload' not in content, content
    match = re.search(r'\[ccr ([0-9a-f]+): 20000 lines,', content)
    assert match, content
    identifier = match[1]
    assert (path / 'ccr' / f'{identifier}.log').read_text() == EXPECTED
    return identifier


def dispatch(body):
    instructions = body.get('instructions', '') + json.dumps(
        [item for item in body['input'] if item.get('role') in ('system', 'developer')])
    role = 'child' if 'You are a sub-agent' in instructions else 'parent'
    path = Path(re.search(r'Scratch directory for (?:this run|this sub-agent): ([^ ]+)', instructions)[1])
    assert path.exists(), path
    if role in paths:
        assert path == paths[role]
    paths[role] = path
    assert 'ccr_retrieve' in {tool.get('name') for tool in body['tools']}
    results = [item['output'] for item in body['input'] if item.get('type') == 'function_call_output']
    users = [item for item in body['input'] if item.get('role') == 'user']
    reset = role == 'parent' and 'after reset' in json.dumps(users[-1])
    seen.append((role, reset, len(results)))
    count = len(results)
    if reset:
        if count == 0:
            assert not (path / 'ccr').exists(), list(path.iterdir())
            return 'ccr_retrieve', {'id': ids['parent'], 'limit': 1}
        status, content = unpack(results[-1])
        assert status['is_error'] and 'no cached output' in content, results[-1]
        return None
    if count == 0:
        if role == 'child':
            assert path != paths['parent']
        return 'bash', {'command': COMMAND}
    if count == 1:
        ids[role] = cached(results[-1], path)
        return 'ccr_retrieve', {'id': ids[role], 'offset': 1, 'limit': 2}
    if count == 2:
        status, content = unpack(results[-1])
        assert not status['is_error'], results[-1]
        assert '1:ROW-00000 payload' in content and '2:ROW-00001 payload' in content, content
        assert 'ROW-00002' not in content, content
        return 'ccr_retrieve', {'id': ids[role], 'query': 'row-12345', 'limit': 2}
    if count == 3:
        status, content = unpack(results[-1])
        assert not status['is_error'] and '12346:ROW-12345 payload' in content, results[-1]
        if role == 'parent':
            return 'subagent', {'task': 'Generate a long bash result, retrieve it, and report.', 'title': 'Cache child output'}
        # The child cannot read its parent's cache, even knowing its id.
        return 'ccr_retrieve', {'id': ids['parent'], 'limit': 1}
    if role == 'child':
        status, content = unpack(results[-1])
        assert status['is_error'] and 'no cached output' in content, results[-1]
    else:
        status, content = unpack(results[-1])
        assert not status['is_error'], results[-1]
        assert not paths['child'].exists(), paths['child']
        assert (path / 'ccr' / f"{ids['parent']}.log").exists()
    return None


class API(http.server.BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass

    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers['Content-Length'])))
        try:
            call = dispatch(body)
        except Exception as error:
            errors.append(error)
            call = None
        output = ([{'type': 'function_call', 'call_id': f'ccr-{len(seen)}',
                    'name': call[0], 'arguments': json.dumps(call[1])}] if call else
                  [{'type': 'message', 'role': 'assistant', 'content': [
                      {'type': 'output_text', 'text': 'CCR done'}]}])
        send_response(self, body, {'status': 'completed', 'output': output})


server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), API)
threading.Thread(target=server.serve_forever, daemon=True).start()
try:
    with tempfile.TemporaryDirectory(prefix='zagent-ccr-test-') as directory:
        root = Path(directory)
        scratch = root / 'tmp'
        scratch.mkdir()
        env = {'PATH': '/usr/bin:/bin', 'HOME': directory, 'XDG_CONFIG_HOME': directory,
               'TMPDIR': str(scratch), 'TERM': 'dumb',
               'AI_URL': f'http://127.0.0.1:{server.server_port}/v1',
               'AI_MODEL': 'mock', 'AI_KEY': 'test'}
        trust_workspace(directory, env)
        result = subprocess.run([str(BINARY)], cwd=directory, env=env,
                                input='cache output\n/new\nafter reset\n/quit\n',
                                text=True, capture_output=True, timeout=90)
        assert result.returncode == 0, result.stderr
        assert not errors, errors
        assert len(seen) == 12, seen
        assert set(ids) == {'parent', 'child'}, ids
        assert all(not path.exists() for path in paths.values()), paths
        assert not list(scratch.iterdir()), list(scratch.iterdir())
finally:
    server.shutdown()
    server.server_close()

print('ccr dispatch integration: ok')
