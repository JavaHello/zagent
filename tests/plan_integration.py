#!/usr/bin/env python3
"""The plan lives in memory and in the session snapshot, not in a file of its own."""
import http.server
import json
from pathlib import Path
import re
import subprocess
import tempfile
import threading

from mock_api import send_response, trust_workspace

binary = Path(__file__).resolve().parents[1] / 'zig-out/bin/zagent'
requests = []
calls = [
    ('plan', {'steps': [
        {'title': 'Read the tool schemas', 'status': 'completed'},
        {'title': 'Write src/plan.zig', 'status': 'in_progress'},
        {'title': 'Wire the plan tool'},
    ]}),
    ('plan', {'index': 2, 'status': 'completed', 'note': 'compiles'}),
    ('plan', {'index': 9, 'status': 'completed'}),
    ('plan', {'status': 'completed'}),
    ('plan', {}),
    ('plan', {'index': 3, 'status': 'in_progress'}),
    ('plan', {'steps': [{'title': 'Rejected alias', 'status': 'active'}]}),
    ('plan', {'steps': [{'title': 'Rejected alias', 'status': 'done'}]}),
    ('plan', {'index': 3, 'status': 'active'}),
    ('plan', {'index': 3, 'status': 'done'}),
]


class API(http.server.BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass

    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers['Content-Length'])))
        requests.append(body)
        index = len(requests) - 1
        if index < len(calls):
            name, arguments = calls[index]
            output = [{'type': 'function_call', 'call_id': f'plan-{index}',
                       'name': name, 'arguments': json.dumps(arguments)}]
        else:
            output = [{'type': 'message', 'role': 'assistant', 'content': [
                {'type': 'output_text', 'text': 'Done'}]}]
        send_response(self, body, {'status': 'completed', 'output': output})


def instructions(body):
    return body.get('instructions', '') + json.dumps(
        [item for item in body['input'] if item.get('role') in ('system', 'developer')],
        ensure_ascii=False)


def status_of(output):
    header, content = output.split('\n', 1)
    assert header.startswith('[tool_status ') and header.endswith(']'), output
    return json.loads(header[len('[tool_status '):-1])['is_error'], content


server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), API)
threading.Thread(target=server.serve_forever, daemon=True).start()
try:
    with tempfile.TemporaryDirectory(prefix='zagent-plan-') as directory:
        env = {'PATH': '/usr/bin:/bin', 'HOME': directory, 'XDG_CONFIG_HOME': directory,
               'TERM': 'dumb', 'AI_URL': f'http://127.0.0.1:{server.server_port}/v1',
               'AI_MODEL': 'mock', 'AI_KEY': 'test'}
        state = trust_workspace(directory, env)

        def run(*args, stdin=''):
            result = subprocess.run([str(binary), *args], cwd=directory, env=env,
                                    input=stdin, text=True, capture_output=True, timeout=60)
            assert result.returncode == 0, result.stderr
            return result.stdout + result.stderr

        # The prompt gives fixed usage guidance, never runtime plan state.
        output = run('Plan the refactor')
        assert len(requests) == len(calls) + 1, (len(requests), output)
        assert 'with no arguments to read the complete current plan' in instructions(requests[0])
        assert all(instructions(body) == instructions(requests[0]) for body in requests)
        assert 'No plan is saved yet' not in instructions(requests[0])
        plan_schema = next(tool['parameters'] for tool in requests[0]['tools']
                           if tool.get('name') == 'plan')
        properties = plan_schema['properties']
        for status in (properties['status'], properties['steps']['items']['properties']['status']):
            assert status['enum'] == ['pending', 'in_progress', 'completed', 'blocked'], status
        session = re.search(r'(?:Session\s+|Session: )([a-f0-9]{32})', output)[1]
        snapshot = state / 'sessions' / f'{session}.json'

        results = [status_of(item['output']) for item in requests[-1]['input']
                   if item.get('type') == 'function_call_output']
        assert len(results) == len(calls), results

        # Mutations acknowledge only the change, without repeating the checklist.
        assert results[0] == (False, 'Plan saved: 3 steps, 1 completed, 0 blocked.\n'), results[0]
        assert results[1] == (False, 'Step 2: in_progress -> completed; note updated.\n'), results[1]

        # A step that is not there, and a status with no step to apply it to,
        # are reported as errors rather than silently applied.
        assert results[2][0] and 'no step 9' in results[2][1], results[2]
        assert results[3][0] and "'index'" in results[3][1], results[3]

        # Reading it back needs no arguments.
        assert not results[4][0]
        assert '2/3 done' in results[4][1], results[4][1]

        assert '1. [x] Read the tool schemas' in results[4][1], results[4]
        assert '2. [x] Write src/plan.zig\n   note: compiles' in results[4][1], results[4]
        assert '3. [ ] Wire the plan tool' in results[4][1], results[4]
        assert results[5] == (False, 'Step 3: pending -> in_progress.\n'), results[5]

        # Neither old enum spelling is accepted, in either tool shape.
        for result in results[6:]:
            assert result[0], result
            assert 'must be pending, in_progress, completed or blocked' in result[1], result

        # Neither titles nor progress leak into the fixed system prompt.
        for body in requests:
            assert 'Write src/plan.zig' not in instructions(body)
            assert '2/3 done' not in instructions(body)

        # Nothing about the plan is a file: it is state of the session, saved in
        # the same snapshot as the messages, and no plan.md exists anywhere.
        assert not list(state.glob('*.md')), list(state.glob('*.md'))
        saved = json.loads(snapshot.read_text())
        assert saved['plan'] == [
            {'title': 'Read the tool schemas', 'status': 'completed', 'note': None},
            {'title': 'Write src/plan.zig', 'status': 'completed', 'note': 'compiles'},
            {'title': 'Wire the plan tool', 'status': 'in_progress', 'note': None},
        ], saved['plan']

        # /plan shows it in the restored session, and /clear keeps it: the plan
        # is not part of the messages that get emptied.
        output = run('--resume', session, stdin='/plan\n/clear\n/quit\n')
        assert '2/3 done. Next: 3. Wire the plan tool' in output, output
        assert '3. [~] Wire the plan tool' in output, output
        assert json.loads(snapshot.read_text())['plan']
        assert json.loads(snapshot.read_text())['messages'] == []

        # Restore keeps runtime state without embedding it in the prompt.
        before = len(requests)
        run('--resume', session, 'where were we?')
        assert len(requests) == before + 1
        assert '2/3 done' not in instructions(requests[-1]), instructions(requests[-1])
        assert 'with no arguments to read the complete current plan' in instructions(requests[-1])

        # /plan clear empties it in memory and in the snapshot.
        output = run('--resume', session, stdin='/plan clear\n/plan\n/quit\n')
        assert 'plan cleared' in output, output
        assert 'No plan saved yet' in output, output
        assert json.loads(snapshot.read_text())['plan'] == [], snapshot.read_text()

        before = len(requests)
        run('--resume', session, 'anything left?')
        assert len(requests) == before + 1
        assert 'No plan is saved yet' not in instructions(requests[-1])
        print('PASS: plan kept in memory, saved with the session, restored and cleared')
finally:
    server.shutdown()
    server.server_close()
