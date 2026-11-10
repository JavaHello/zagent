#!/usr/bin/env python3
"""On-demand memory retrieval, bounded tool contracts and extraction context."""
import http.server
import json
from pathlib import Path
import subprocess
import tempfile
import threading

from mock_api import handle_planning, send_response, trust_workspace

binary = Path(__file__).resolve().parents[1] / 'zig-out/bin/zagent'
requests = []
extractions = []
calls = [
    ('memory_search', {'query': '中文 tmux', 'limit': 1}),
    ('memory_search', {'query': 'nonexistent'}),
    ('memory_search', {'query': ''}),
    ('memory_search', {'query': 'tmux', 'limit': 11}),
    ('memory_search', {'query': 'tmux', 'limit': -1}),
    ('remember', {'text': 'tmux new durable note'}),
    ('memory_search', {'query': 'tmux new', 'limit': 1}),
    ('memory_search', {'query': 'x' * 513}),
]


class API(http.server.BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass

    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers['Content-Length'])))
        if handle_planning(self, body):
            return
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
               'AI_MODEL': 'mock', 'AI_KEY': 'test',
               'AI_MAX_ITERATIONS': '12', 'AI_MEMORY_AUTO': '1', 'AI_MEMORY': '1'}
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
            status = json.loads(output.split('\n', 1)[0][len('[tool_status '):-1])
            assert status['is_error'] == (index in (2, 3, 4, 7)), (index, output)
        assert 'tmux new durable note' in results[6] and relevant not in results[6]
        assert len(extractions) == 1, (extractions, result.stderr)
        extraction = json.dumps(extractions[0], ensure_ascii=False)
        assert relevant in extraction and unrelated not in extraction
finally:
    server.shutdown()
    server.server_close()

print('PASS: on-demand memory, validation, fresh lookups and relevant-only extraction')
