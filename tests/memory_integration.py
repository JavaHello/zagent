#!/usr/bin/env python3
"""On-demand memory retrieval with no extra end-of-turn extraction request."""
import http.server
import json
from pathlib import Path
import subprocess
import tempfile
import threading

from mock_api import send_response, trust_workspace

binary = Path(__file__).resolve().parents[1] / 'zig-out/bin/zagent'
requests = []
extractions = []
calls = [
    ('memory_search', {'query': '中文 tmux', 'limit': 1}),
    ('memory_search', {'query': 'nonexistent'}),
    ('memory_search', {'query': ''}),
    ('memory_search', {'query': 'tmux', 'limit': 11}),
    ('memory_search', {'query': 'tmux', 'limit': -1}),
    ('memory_save', {'text': 'tmux new durable note'}),
    ('memory_search', {'query': 'tmux new', 'limit': 1}),
    ('memory_search', {'query': 'x' * 513}),
]


class API(http.server.BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass

    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers['Content-Length'])))
        if 'You maintain the durable memory' in json.dumps(body['input']):
            extractions.append(body)
            text = '{"remember":[]}'
            output = [{'type': 'message', 'role': 'assistant', 'content': [
                {'type': 'output_text', 'text': text}]}]
        else:
            requests.append(body)
            results = [i for i in body['input'] if i.get('type') == 'function_call_output']
            index = len(results)
            if index < len(calls):
                name, args = calls[index]
                output = [{'type': 'function_call', 'call_id': f'memory-{index}',
                           'name': name, 'arguments': json.dumps(args)}]
            else:
                output = [{'type': 'message', 'role': 'assistant', 'content': [
                    {'type': 'output_text', 'text': 'Done'}]}]
        send_response(self, body, {'status': 'completed', 'output': output})


server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), API)
threading.Thread(target=server.serve_forever, daemon=True).start()
try:
    with tempfile.TemporaryDirectory(prefix='zagent-memory-') as directory:
        env = {'PATH': '/usr/bin:/bin', 'HOME': directory, 'XDG_CONFIG_HOME': directory,
               'AI_URL': f'http://127.0.0.1:{server.server_port}/v1',
               'AI_MODEL': 'mock', 'AI_KEY': 'test'}
        state = trust_workspace(directory, env)
        relevant = '中文 tmux clipboard workaround'
        unrelated = 'UNRELATED_SECRET_SENTINEL build command'
        (state / 'memory.md').write_text(f'# zagent memory\n- {relevant}\n- {unrelated}\n')
        result = subprocess.run([str(binary), 'Check tmux conventions'], cwd=directory,
                                env=env, text=True, capture_output=True, timeout=60)
        assert result.returncode == 0, result.stderr
        assert len(requests) == len(calls) + 1, (len(requests), result.stderr)
        for body in requests:
            # Tool results may contain requested notes, never the unrequested one.
            assert unrelated not in json.dumps(body, ensure_ascii=False)
            instructions = body.get('instructions', '') + json.dumps(
                [i for i in body['input'] if i.get('role') in ('system', 'developer')],
                ensure_ascii=False)
            assert relevant not in instructions
        results = [i['output'] for i in requests[-1]['input']
                   if i.get('type') == 'function_call_output']
        assert relevant in results[0]
        assert 'No matching memories' in results[1]
        for index, output in enumerate(results):
            status = json.loads(output)
            assert status['is_error'] == (index in (2, 3, 4, 7)), (index, output)
        assert 'tmux new durable note' in results[6] and relevant not in results[6]
        assert not extractions, (extractions, result.stderr)
        saved = (state / 'memory.md').read_text()
        assert 'tmux new durable note' in saved
        assert relevant in saved and unrelated in saved
finally:
    server.shutdown()
    server.server_close()

print('PASS: model-driven memory, validation, fresh lookups and no automatic extraction')
