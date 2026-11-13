#!/usr/bin/env python3
"""HTTP error/download contracts and exact durable-memory edits."""
import gzip
import http.server
import json
from pathlib import Path
import subprocess
import tempfile
import threading

from mock_api import send_response, trust_workspace

binary = Path(__file__).resolve().parents[1] / 'zig-out/bin/zagent'
observed = []
calls = []


class API(http.server.BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass

    def do_GET(self):
        status = 404 if self.path == '/missing' else 200
        content = b'not found' if status == 404 else b'downloaded'
        compressed = self.path in ('/gzip', '/chunked-gzip')
        chunked = self.path in ('/chunked-gzip', '/partial-chunked')
        if compressed:
            content = gzip.compress(content)
        self.send_response(status)
        if compressed:
            self.send_header('Content-Encoding', 'gzip')
        if chunked:
            self.send_header('Transfer-Encoding', 'chunked')
        else:
            self.send_header('Content-Length', str(100 if self.path == '/partial' else len(content)))
        self.end_headers()
        if chunked:
            self.wfile.write(f'{len(content):x}\r\n'.encode() + content + b'\r\n')
            if self.path != '/partial-chunked':
                self.wfile.write(b'0\r\n\r\n')
        else:
            self.wfile.write(content)
        self.close_connection = True

    def do_POST(self):
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
threading.Thread(target=server.serve_forever, daemon=True).start()
try:
    with tempfile.TemporaryDirectory(prefix='zagent-tool-contract-') as directory:
        root = Path(directory)
        (root / 'keep.txt').write_text('original')
        base = f'http://127.0.0.1:{server.server_port}'
        calls.extend([
            ('http', {'url': base + '/missing'}),
            ('http', {'url': base + '/missing', 'save_to': 'keep.txt'}),
            ('http', {'url': base + '/partial', 'save_to': 'keep.txt'}),
            ('http', {'url': base + '/ok', 'save_to': 'download.txt'}),
            ('memory_save', {'text': 'use old compiler'}),
            ('memory_save', {'action': 'replace', 'old_text': 'use old compiler', 'text': 'use Zig 0.17.1'}),
            ('memory_save', {'action': 'delete', 'text': 'use Zig 0.17.1'}),
            ('memory_save', {'action': 'delete', 'text': 'use old compiler'}),
            ('http', {'url': base + '/gzip', 'save_to': 'gzip.txt'}),
            ('http', {'url': base + '/chunked-gzip', 'save_to': 'chunked-gzip.txt'}),
            ('http', {'url': base + '/partial-chunked', 'save_to': 'keep.txt'}),
        ])
        env = {'PATH': '/usr/bin:/bin', 'HOME': directory, 'XDG_CONFIG_HOME': directory,
               'AI_URL': base + '/v1', 'AI_MODEL': 'mock',
               'AI_KEY': 'local-test'}
        trust_workspace(directory, env)
        result = subprocess.run([str(binary), 'Exercise tool contracts'], cwd=directory,
                                env=env, capture_output=True, text=True, timeout=60)
        assert result.returncode == 0, result.stderr
        assert len(observed) == len(calls), (observed, result.stderr)
        for index, output in enumerate(observed):
            prefix = output.split('\n', 1)[0]
            assert prefix.startswith('[tool_status '), output
            status = json.loads(prefix[len('[tool_status '):-1])
            assert status['is_error'] == (index in (0, 1, 2, 7, 10)), (index, output)
        assert (root / 'keep.txt').read_text() == 'original'
        for name in ('download.txt', 'gzip.txt', 'chunked-gzip.txt'):
            assert (root / name).read_bytes() == b'downloaded'
        assert 'Memory replace: use Zig 0.17.1' in observed[5]
        assert 'Memory delete: use Zig 0.17.1' in observed[6]
        assert 'MemoryNotFound' in observed[7]
finally:
    server.shutdown()
    server.server_close()

print('PASS: HTTP errors, atomic downloads, and exact memory replacement/deletion')
