#!/usr/bin/env python3
"""A sub-agent runs on two clocks the caller sets. A self-check asks it for a
progress report, which is printed on the terminal and goes no further; the
deadline stops the work and its final report is what the caller reads back."""
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

# The order of these replies is the order of the run itself: the caller starts a
# run self-checked at its first boundary with a deadline one second away, the
# child reports, works past the deadline with a slow command, and is told to
# finish when it comes back.
script = [
    ('subagent', {'task': 'Split the source tree into one file per tool.',
                  'title': 'Split the tree', 'self_check_seconds': 0, 'deadline_seconds': 1}),
    ('report', {'summary': 'two of the four tools are split; nothing verified yet'}),
    ('bash', {'command': 'sleep 2'}),
    ('answer', {'text': 'Final report: two files split, the other two are untouched.'}),
    ('answer', {'text': 'Read the final report.'}),
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
    result = json.loads(output)
    content = result.pop('output')
    result.pop('ccr_id')
    return result['is_error'], content


def call_id_of(body, name):
    for item in body['input']:
        if item.get('type') == 'function_call' and item.get('name') == name:
            return item['call_id']
    raise AssertionError(f'no {name} call in {body["input"]}')


server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), API)
threading.Thread(target=server.serve_forever, daemon=True).start()
try:
    with tempfile.TemporaryDirectory(prefix='zagent-selfcheck-') as directory:
        env = {'PATH': '/usr/bin:/bin', 'HOME': directory, 'XDG_CONFIG_HOME': directory,
               'TERM': 'dumb', 'AI_URL': f'http://127.0.0.1:{server.server_port}/v1',
               'AI_MODEL': 'mock', 'AI_KEY': 'test'}
        state = trust_workspace(directory, env)

        result = subprocess.run([str(binary), 'Split the tools'], cwd=directory, env=env,
                                input='', text=True, capture_output=True, timeout=120)
        assert result.returncode == 0, result.stderr

        assert len(requests) == len(script), (len(requests), [is_subagent(body) for body in requests])
        parent = [body for body in requests if not is_subagent(body)]
        child = [body for body in requests if is_subagent(body)]
        assert len(parent) == 2 and len(child) == 3, (len(parent), len(child))

        # The self-check reaches the child as a line of its own conversation, and
        # it answers with the report tool rather than with its final answer.
        child_first = json.dumps(child[0]['input'], ensure_ascii=False)
        assert 'check-in interval has passed' in child_first, child_first
        assert 'report' in tool_names(child[0]), tool_names(child[0])
        # The report tool belongs to the child; the caller never holds it.
        assert 'report' not in tool_names(parent[0]), tool_names(parent[0])
        assert 'subagent_stop' not in tool_names(parent[0]), tool_names(parent[0])

        # The report comes back to the child as permission to carry on, not as a
        # question, and the run is not paused anywhere.
        child_second = json.dumps(child[1]['input'], ensure_ascii=False)
        assert "printed on the caller's terminal" in child_second, child_second

        # The deadline is what ends the work: the next boundary the child
        # reaches is after it, and the report that was asked for is the one the
        # caller reads.
        child_third = json.dumps(child[2]['input'], ensure_ascii=False)
        assert 'deadline has passed' in child_third, child_third
        finish_call = call_id_of(parent[1], 'subagent')
        failed, final = status_of(tool_output(parent[1], finish_call))
        assert not failed, final
        assert 'reached its deadline' in final, final
        assert 'two files split, the other two are untouched' in final, final
        # Nothing of the self-check came back with it: the report went to the
        # terminal, and the tool result is the end of the run alone.
        assert 'two of the four tools are split' not in final, final

        # It was printed for the user instead, on a line that names the run.
        assert 'self-check' in result.stderr, result.stderr
        assert 'two of the four tools are split' in result.stderr, result.stderr
        assert 's1 "Split the tree"' in result.stderr, result.stderr
        # The call's name is styled and its arguments dimmed, so the line is
        # read with the terminal codes taken out of it.
        plain = re.sub(r'\x1b\[[0-9;]*[A-Za-z]', '', result.stderr)
        assert '⇢ subagent' in plain and 'Split the tree' in plain, result.stderr

        # The run keeps its own session, with the self-check it answered in it,
        # and the child's scratch directory went with the child.
        sessions = sorted((state / 'sessions').glob('*.json'))
        assert len(sessions) == 2, sessions
        caller_session = next(path for path in sessions if '.json.s' not in path.name)
        assert json.loads(caller_session.read_text())['child'] is None, 'the caller session is the run\'s'
        run_session = json.loads((state / 'sessions' / f'{caller_session.name}.s1.json').read_text())
        assert run_session['child']['id'] == 's1', run_session['child']
        assert run_session['child']['title'] == 'Split the tree', run_session['child']
        assert run_session['child']['status'] == 'completed', run_session['child']
        assert any(call['name'] == 'report'
                   for message in run_session['messages'] for call in message.get('tool_calls') or []), run_session['messages']
        assert 'two files split' in (run_session['messages'][-1].get('content') or ''), run_session['messages']
        assert not Path(scratch_of(child[0])).exists(), 'the child scratch outlived the child'

        assert 'Read the final report.' in result.stdout, result.stdout
        assert 'two files split' not in result.stdout, result.stdout
        print('PASS: a self-check goes to the terminal, and the deadline ends the run with its final report')
finally:
    server.shutdown()
    server.server_close()
