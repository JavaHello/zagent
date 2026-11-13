#!/usr/bin/env python3
"""Each Responses call contributes only reported usage, including detail subsets."""
import http.server
import json
from pathlib import Path
import subprocess
import tempfile
import threading

from mock_api import send_response, trust_workspace

binary = Path(__file__).resolve().parents[1] / 'zig-out/bin/zagent'
calls = 0
report_usage = True
cache_mode = 'reported'
requests = []


class API(http.server.BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass

    def do_POST(self):
        global calls
        request = json.loads(self.rfile.read(int(self.headers['Content-Length'])))
        requests.append(request)
        calls += 1
        if calls == 1:
            output = [{'type': 'function_call', 'call_id': 'count-call',
                       'name': 'bash', 'arguments': json.dumps({'command': 'echo counted'})}]
        else:
            output = [{'type': 'message', 'role': 'assistant',
                       'content': [{'type': 'output_text', 'text': 'Done'}]}]
        payload = {'status': 'completed', 'output': output}
        if report_usage or calls == 1:
            payload['usage'] = {
                'input_tokens': 100 * calls, 'output_tokens': 20 * calls,
                'total_tokens': 120 * calls,
                'output_tokens_details': {'reasoning_tokens': 12 * calls},
            }
            if cache_mode != 'missing':
                payload['usage']['input_tokens_details'] = {
                    'cached_tokens': 0 if cache_mode == 'zero' else 60 * calls}
        send_response(self, request, payload)


server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), API)
threading.Thread(target=server.serve_forever, daemon=True).start()
try:
    with tempfile.TemporaryDirectory(prefix='zagent-usage-') as directory:
        env = {'PATH': '/usr/bin:/bin', 'HOME': directory, 'XDG_CONFIG_HOME': directory,
               'AI_URL': f'http://127.0.0.1:{server.server_port}/v1', 'AI_KEY': 'test',
               'AI_MODEL': 'mock'}
        trust_workspace(directory, env)
        scenarios = (
            (True, 'reported', 'cached 180, reported; cache reports 2/2'),
            (False, 'reported', 'cached 60, partial; cache reports 1/2'),
            (True, 'missing', 'cached 0, unknown; cache reports 0/2'),
            (True, 'zero', 'cached 0, reported; cache reports 2/2'),
        )
        for cache_options in ({}, {'AI_PROMPT_CACHE_RETENTION': '24h'}):
            for report_usage, cache_mode, cached_summary in scenarios:
                calls = 0
                requests.clear()
                result = subprocess.run([str(binary), 'Run the command then answer'],
                                        cwd=directory, env={**env, **cache_options},
                                        capture_output=True, text=True, timeout=20)
                assert result.returncode == 0, result.stderr
                assert calls == 2, calls
                assert len(requests) == 2, requests
                for request in requests:
                    if 'AI_PROMPT_CACHE_RETENTION' in cache_options:
                        assert (request.get('prompt_cache_retention') ==
                                cache_options['AI_PROMPT_CACHE_RETENTION']), request
                    else:
                        assert 'prompt_cache_retention' not in request, request
                expected = (f'in 300 ({cached_summary}) · out 60 (reasoning 36) · '
                            'total 360 tokens · usage 2/2 calls'
                            if report_usage else
                            f'in 100 ({cached_summary}) · out 20 (reasoning 12) · '
                            'total 120 tokens · usage 1/2 calls')
                assert expected in result.stderr, result.stderr
        print('PASS: per-call usage sums, partial/unknown/zero cache reports, '
              'missing usage not estimated, optional cache HTTP fields and absent defaults')

finally:
    server.shutdown()
    server.server_close()
