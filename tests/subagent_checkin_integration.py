#!/usr/bin/env python3
"""A sub-agent has no limits of its own: the caller watches it. At the check-in
the child is asked for a progress report, the run pauses there, and the caller
decides — here, to stop it and take its final report."""
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

# The order of these replies is the order of the handshake: the caller starts a
# run checked in at its first boundary, the child reports, the caller stops it,
# the child writes its last reply, the caller answers.
script = [
    ('subagent', {'task': 'Split the source tree into one file per tool.',
                  'title': 'Split the tree', 'checkin_seconds': 0}),
    ('report', {'summary': 'two of the four tools are split; nothing verified yet'}),
    ('subagent_stop', {'id': 's1'}),
    ('answer', {'text': 'Final report: two files split, the other two are untouched.'}),
    ('answer', {'text': 'Stopped the run.'}),
]
index = 0


class API(http.server.BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass

    def do_POST(self):
        global index
        body = json.loads(self.rfile.read(int(self.headers['Content-Length'])))
        requests.append(body)
        kind, payload = script[index] if index < len(script) else ('answer', {'text': 'done'})
        index += 1
        if kind == 'answer':
            output = [{'type': 'message', 'role': 'assistant',
                       'content': [{'type': 'output_text', 'text': payload['text']}]}]
        else:
            output = [{'type': 'function_call', 'call_id': f'{kind}-{index}',
                       'name': kind, 'arguments': json.dumps(payload)}]
        send_response(self, body, {'status': 'completed', 'output': output})


def instructions(body):
    return body.get('instructions', '') + json.dumps(
        [item for item in body['input'] if item.get('role') in ('system', 'developer')],
        ensure_ascii=False)


def is_subagent(body):
    return 'You are a sub-agent' in instructions(body)


def tool_names(body):
    return {tool.get('name') for tool in body.get('tools') or []}


def scratch_of(body):
    match = re.search(r'Scratch directory for (?:this run|this sub-agent): ([^ ]+)', instructions(body))
    return match[1] if match else None


def tool_output(body, call_id):
    for item in body['input']:
        if item.get('type') == 'function_call_output' and item.get('call_id') == call_id:
            return item['output']
    return None


def status_of(output):
    header, content = output.split('\n', 1)
    assert header.startswith('[tool_status ') and header.endswith(']'), output
    return json.loads(header[len('[tool_status '):-1])['is_error'], content


def call_id_of(body, name):
    for item in body['input']:
        if item.get('type') == 'function_call' and item.get('name') == name:
            return item['call_id']
    raise AssertionError(f'no {name} call in {body["input"]}')


server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), API)
threading.Thread(target=server.serve_forever, daemon=True).start()
try:
    with tempfile.TemporaryDirectory(prefix='zagent-checkin-') as directory:
        env = {'PATH': '/usr/bin:/bin', 'HOME': directory, 'XDG_CONFIG_HOME': directory,
               'TERM': 'dumb', 'AI_URL': f'http://127.0.0.1:{server.server_port}/v1',
               'AI_MODEL': 'mock', 'AI_KEY': 'test', 'AI_MAX_ITERATIONS': '12'}
        state = trust_workspace(directory, env)

        result = subprocess.run([str(binary), 'Split the tools'], cwd=directory, env=env,
                                input='', text=True, capture_output=True, timeout=120)
        assert result.returncode == 0, result.stderr

        assert len(requests) == len(script), (len(requests), [is_subagent(body) for body in requests])
        parent = [body for body in requests if not is_subagent(body)]
        child = [body for body in requests if is_subagent(body)]
        assert len(parent) == 3 and len(child) == 2, (len(parent), len(child))

        # The check-in reaches the child as a line of its own conversation, and
        # it answers with the report tool rather than with its final answer.
        child_first = json.dumps(child[0]['input'], ensure_ascii=False)
        assert 'needs a progress report now' in child_first, child_first
        assert 'report' in tool_names(child[0]), tool_names(child[0])
        # The report tool belongs to the child, and stopping a run to the caller.
        assert 'report' not in tool_names(parent[0]), tool_names(parent[0])
        assert 'subagent_stop' in tool_names(parent[0]), tool_names(parent[0])
        assert 'subagent_stop' not in tool_names(child[0]), tool_names(child[0])

        # The paused run comes back as a progress report that names the id the
        # caller answers with, and it is not an error: the run is alive.
        progress_call = call_id_of(parent[1], 'subagent')
        failed, report = status_of(tool_output(parent[1], progress_call))
        assert not failed, report
        assert 'progress report' in report, report
        assert 'two of the four tools are split' in report, report
        assert 'subagent_stop' in report and '"s1"' in report, report
        assert 'Final report' not in report, report
        # The run was named when it was started, so the report names it the
        # same way the terminal does, and the caller reading two of them can
        # tell which run it is looking at.
        assert 's1 "Split the tree" progress report' in report, report
        assert '⇢ subagent' in result.stderr and 'Split the tree' in result.stderr, result.stderr

        # Stopped, the child is told twice: as the verdict on the report it was
        # waiting at, and again at the only boundary it had left.
        child_second = json.dumps(child[1]['input'], ensure_ascii=False)
        assert 'Do no further work' in child_second, child_second
        assert 'has stopped this task' in child_second, child_second

        # What the caller reads back is the child's final report, not its
        # transcript and not the earlier commentary.
        stop_call = call_id_of(parent[2], 'subagent_stop')
        failed, final = status_of(tool_output(parent[2], stop_call))
        assert not failed, final
        assert 'Sub-agent stopped' in final, final
        assert 'two files split, the other two are untouched' in final, final
        assert 'two of the four tools are split' not in final, final

        # The run is over: the session is the caller's alone, and the child's
        # scratch directory went with it.
        sessions = list((state / 'sessions').glob('*.json'))
        assert len(sessions) == 1, sessions
        assert not Path(scratch_of(child[0])).exists(), 'the child scratch outlived the child'

        assert 'Stopped the run.' in result.stdout, result.stdout
        assert 'Final report' not in result.stdout, result.stdout
        print('PASS: a check-in pauses the sub-agent, and the caller stops it with its final report')
finally:
    server.shutdown()
    server.server_close()
