#!/usr/bin/env python3
"""A patch in another format is refused with the Git diff to send instead, and
what the model is told about the tool carries a patch it can copy."""
import http.server
import json
from pathlib import Path
import subprocess
import tempfile
import threading

from mock_api import send_response, trust_workspace

binary = Path(__file__).resolve().parents[1] / 'zig-out/bin/zagent'
requests = []

# The format that costs the most turns when it comes back unread: the change
# itself is right, and every line of it is on the wrong side of the header.
SENTINEL = ('*** Begin Patch\n'
            '*** Update File: notes.md\n'
            '@@ -1,2 +1,2 @@\n'
            ' # Report\n'
            '-Analysis complete.\n'
            '+Analysis verified.\n'
            '*** End Patch\n')

GIT = ('--- a/notes.md\n'
       '+++ b/notes.md\n'
       '@@ -1,2 +1,2 @@\n'
       ' # Report\n'
       '-Analysis complete.\n'
       '+Analysis verified.\n')

calls = [
    ('write', {'path': 'notes.md', 'content': '# Report\nAnalysis complete.\n'}),
    ('apply_patch', {'patch': SENTINEL}),
    ('apply_patch', {'patch': GIT}),
]


class API(http.server.BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass

    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers['Content-Length'])))
        requests.append(body)
        results = [item for item in body['input'] if item.get('type') == 'function_call_output']
        index = len(results)
        if index < len(calls):
            name, arguments = calls[index]
            output = [{'type': 'function_call', 'call_id': f'patch-{index}',
                       'name': name, 'arguments': json.dumps(arguments)}]
        else:
            output = [{'type': 'message', 'role': 'assistant', 'content': [
                {'type': 'output_text', 'text': 'Done'}]}]
        send_response(self, body, {'status': 'completed', 'output': output})


def status_of(output):
    status = json.loads(output)
    content = status.pop('output')
    status.pop('ccr_id')
    return status['is_error'], content


def description(name):
    tool = next(item for item in requests[0]['tools'] if item.get('name') == name)
    return tool['description']


server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), API)
threading.Thread(target=server.serve_forever, daemon=True).start()
try:
    with tempfile.TemporaryDirectory(prefix='zagent-patch-') as directory:
        env = {'PATH': '/usr/bin:/bin', 'HOME': directory, 'XDG_CONFIG_HOME': directory,
               'TERM': 'dumb', 'AI_URL': f'http://127.0.0.1:{server.server_port}/v1',
               'AI_MODEL': 'mock', 'AI_KEY': 'test'}
        trust_workspace(directory, env)
        result = subprocess.run([str(binary), 'Change the report'], cwd=directory, env=env,
                                text=True, capture_output=True, timeout=120)
        assert result.returncode == 0, result.stderr
        assert len(requests) == len(calls) + 1, len(requests)

        # The tool is described with a patch that can be copied as it is: a
        # header pair, a hunk of the right counts, and every line carrying its
        # own marker.
        patch_description = description('apply_patch')
        assert ('--- a/greet.txt\n'
                '+++ b/greet.txt\n'
                '@@ -1,3 +1,3 @@\n'
                ' alpha\n'
                '-beta\n'
                '+hello\n'
                ' gamma\n') in patch_description, patch_description
        assert 'Git unified diff' in patch_description, patch_description

        results = [status_of(item['output']) for item in requests[-1]['input']
                   if item.get('type') == 'function_call_output']
        assert len(results) == len(calls), results

        # The sentinel format is refused, by name, with the same change written
        # the way this tool reads it — the path it named, and the way to say a
        # single block without any of that.
        refused, message = results[1]
        assert refused, results[1]
        assert message.startswith('Error: nothing was applied'), message
        assert '*** Update File: ' in message, message
        assert '--- a/notes.md\n+++ b/notes.md' in message, message
        assert 'edit(path, old_text, new_text)' in message, message

        # The Git diff of the same change is the whole of the work, applied
        # once: the refusal wrote nothing that the second call had to undo.
        applied, message = results[2]
        assert not applied, results[2]
        assert 'Applied 1 file: notes.md (+1 -1)' in message, message
        assert Path(directory, 'notes.md').read_text() == '# Report\nAnalysis verified.\n'

        print('PASS: the sentinel patch format is refused with the Git diff to send, and the '
              'description carries one that applies')
finally:
    server.shutdown()
    server.server_close()
