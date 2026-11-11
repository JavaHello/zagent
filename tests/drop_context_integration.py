#!/usr/bin/env python3
"""The model can drop an earlier tool result, and the call stays paired."""
import http.server
import json
import os
from pathlib import Path
import re
import subprocess
import tempfile
import threading

from mock_api import send_response, trust_workspace

binary = Path(__file__).resolve().parents[1] / 'zig-out/bin/zagent'
requests = []
dropped_marker = 'Tool result dropped by the model: bash (call run-1)'


class API(http.server.BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass

    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers['Content-Length'])))
        requests.append(body)
        names = [tool.get('name') for tool in body.get('tools') or []]
        assert 'drop_context' in names, names
        results = [item for item in body['input']
                   if item.get('type') == 'function_call_output']
        if not results:
            call = ('bash', {'command': 'seq 1 50'})
        elif len(results) == 1:
            assert '50' in results[0]['output'], results[0]['output']
            call = ('drop_context', {'call_ids': ['run-1']})
        else:
            # The dropped result is a marker, not the output it replaced, and
            # the assistant call that produced it is still in the request.
            outputs = {item['call_id']: item['output'] for item in results}
            assert dropped_marker in outputs['run-1'], outputs['run-1']
            assert '49' not in outputs['run-1'], outputs['run-1']
            assert 'Dropped 1 tool result(s)' in outputs['drop-1'], outputs['drop-1']
            assert any(item.get('type') == 'function_call'
                       and item.get('call_id') == 'run-1' for item in body['input'])
            call = None
        output = ([{'type': 'function_call', 'call_id': f'drop-{len(results)}'
                    if len(results) else 'run-1', 'name': call[0],
                    'arguments': json.dumps(call[1])}] if call else
                  [{'type': 'message', 'role': 'assistant', 'content': [
                      {'type': 'output_text', 'text': 'Done'}]}])
        send_response(self, body, {'status': 'completed', 'output': output})


server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), API)
threading.Thread(target=server.serve_forever, daemon=True).start()
try:
    with tempfile.TemporaryDirectory(prefix='zagent-drop-') as directory:
        env = dict(os.environ, HOME=directory, XDG_STATE_HOME=directory,
                   XDG_CONFIG_HOME=directory, TERM='dumb',
                   AI_KEY='test', AI_MODEL='mock',
                   AI_URL=f'http://127.0.0.1:{server.server_port}/v1')
        env.pop('AI_PROVIDER', None)
        state = trust_workspace(directory, env)
        result = subprocess.run([str(binary), 'drop the build output'], cwd=directory,
                                env=env, input='', text=True, capture_output=True,
                                timeout=60)
        assert result.returncode == 0, result.stderr
        assert len(requests) == 3, len(requests)
        # The drop is a history edit: the session keeps the marker, so a resume
        # replays exactly what the model was last given.
        sid = re.search(r'Session: ([a-f0-9]{32})', result.stdout + result.stderr)[1]
        saved = json.loads((state / 'sessions' / f'{sid}.json').read_text())
        contents = [m.get('content') or '' for m in saved['messages']]
        assert any(dropped_marker in content for content in contents), contents
        assert not any('49\n50' in content for content in contents), contents
    print('drop_context integration: ok')
finally:
    server.shutdown()
