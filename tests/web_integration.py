#!/usr/bin/env python3
"""The web tools: a configured search and fetch service, and a page read locally."""
import http.server
import json
from pathlib import Path
import subprocess
import tempfile
import threading

from mock_api import send_response, trust_workspace

binary = Path(__file__).resolve().parents[1] / 'zig-out/bin/zagent'
paths = []
authorization = {}

PAGE = (b'<html><head><title>Local Page</title>'
        b'<style>b{color:red}</style></head><body>'
        b'<h1>Heading</h1><p>Words.</p>'
        b'<script>var hidden = 1;</script></body></html>')

class API(http.server.BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass

    def do_GET(self):
        paths.append(self.path)
        authorization[self.path.split('?')[0]] = self.headers.get('Authorization')
        if self.path.startswith('/search'):
            body = json.dumps({'results': [
                {'title': 'Zig', 'url': 'https://ziglang.org/', 'content': 'A language.'},
                {'title': 'Docs', 'url': 'https://zig.dev/', 'description': 'How to.'},
                {'title': 'Third', 'url': 'https://third.test/'},
            ]}).encode()
            content_type = 'application/json'
        elif self.path.startswith('/reader/'):
            body = b'# Read by the service\n\nIt already returned markdown.\n'
            content_type = 'text/markdown'
        elif self.path == '/page':
            body, content_type = PAGE, 'text/html; charset=utf-8'
        else:
            body, content_type = b'not found', 'text/plain'
        self.send_response(200 if self.path == '/page' or self.path.startswith(('/search', '/reader/')) else 404)
        self.send_header('Content-Type', content_type)
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_POST(self):
        calls = self.server.calls
        observed = self.server.observed
        body = json.loads(self.rfile.read(int(self.headers['Content-Length'])))
        results = [item for item in body['input'] if item.get('type') == 'function_call_output']
        if len(results) > len(observed):
            observed.append(results[-1]['output'])
        index = len(results)
        if index < len(calls):
            name, arguments = calls[index]
            output = [{'type': 'function_call', 'call_id': f'call-{index}',
                       'name': name, 'arguments': json.dumps(arguments)}]
        else:
            output = [{'type': 'message', 'role': 'assistant', 'content': [
                {'type': 'output_text', 'text': 'Done'}]}]
        send_response(self, body, {'status': 'completed', 'output': output})

server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), API)
server.calls = []
server.observed = []
threading.Thread(target=server.serve_forever, daemon=True).start()

def drive(directory, base, calls, extra_env=None):
    """Run one session through `calls`, returning what each tool answered."""
    server.calls = calls
    server.observed = []
    env = {'PATH': '/usr/bin:/bin', 'HOME': directory, 'XDG_CONFIG_HOME': directory,
           'AI_URL': base + '/v1', 'AI_MODEL': 'mock', 'AI_KEY': 'local-test'}
    env.update(extra_env or {})
    trust_workspace(directory, env)
    result = subprocess.run([str(binary), 'Exercise the web tools'], cwd=directory,
                            env=env, capture_output=True, text=True, timeout=60)
    assert result.returncode == 0, result.stderr
    assert len(server.observed) == len(calls), (server.observed, result.stderr)
    return [json.loads(output) for output in server.observed]

try:
    with tempfile.TemporaryDirectory(prefix='zagent-web-') as directory:
        base = f'http://127.0.0.1:{server.server_port}'

        # Both tools with a service of their own: the query goes to the search
        # endpoint, the page is asked for through the reader, and the key rides
        # along as a bearer token.
        answered = drive(directory, base, [
            ('web_search', {'query': 'zig lang', 'limit': 2}),
            ('web_fetch', {'url': base + '/page'}),
        ], {
            'WEB_SEARCH_URL': base + '/search?q={query}&n={limit}',
            'WEB_SEARCH_KEY': 'search-key',
            'WEB_FETCH_URL': base + '/reader/',
            'WEB_FETCH_KEY': 'fetch-key',
        })
        search = answered[0]
        assert not search['is_error'], search
        assert '1. Zig' in search['output'], search['output']
        assert '   https://ziglang.org/' in search['output'], search['output']
        assert '   A language.' in search['output'], search['output']
        assert '2. Docs' in search['output'], search['output']
        assert 'Third' not in search['output'], search['output']
        assert authorization['/search'] == 'Bearer search-key', authorization

        fetch = answered[1]
        assert not fetch['is_error'], fetch
        assert fetch['output'] == '# Read by the service\n\nIt already returned markdown.\n', fetch
        assert authorization['/reader/' + base + '/page'] == 'Bearer fetch-key', authorization

        # With nothing configured the page is fetched here and read as text: its
        # title and heading, without the style or the script around them.
        local = drive(directory, base, [('web_fetch', {'url': base + '/page'})])
        page = local[0]
        assert not page['is_error'], page
        assert page['output'] == '# Local Page\n\n# Heading\n\nWords.\n', page['output']
        assert '/search' not in paths or authorization['/search'] == 'Bearer search-key'
finally:
    server.shutdown()
    server.server_close()

print('PASS: a configured search and reader service, and a page read locally')
