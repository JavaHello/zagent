#!/usr/bin/env python3
"""A sub-agent is a second agent in the same process: its own conversation and
tools, the caller's terminal, session and plan; a report comes back, not a
transcript."""
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

# What the parent and the child ask for, in the order the server sees it. The
# child's requests are the ones whose instructions name a sub-agent.
script = [
    ('subagent', {'task': '   '}),
    ('subagent', {'task': 'Run one command and report what it printed.',
                  'context': 'The workspace is empty; nothing needs cleaning up.'}),
    ('bash', {'command': "printf 'child ran a tool\\n'"}),
    ('answer', {'text': 'Ran bash. It printed one line; nothing else changed.'}),
    ('answer', {'text': 'Delegation done.'}),
]
index = 0
# Whether the sub-agent's own scratch directory existed while it was working:
# it is removed when the agent finishes, so this cannot be asked afterwards.
child_scratch_live = []


class API(http.server.BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass

    def do_POST(self):
        global index
        body = json.loads(self.rfile.read(int(self.headers['Content-Length'])))
        requests.append(body)
        kind, payload = script[index] if index < len(script) else ('answer', {'text': 'done'})
        index += 1
        if 'You are a sub-agent' in instructions(body):
            child_scratch_live.append(Path(scratch_of(body) or '/nonexistent').exists())
        if kind == 'answer':
            output = [{'type': 'message', 'role': 'assistant',
                       'content': [{'type': 'output_text', 'text': payload['text']}]}]
        else:
            output = []
            if kind == 'bash':
                # Commentary before a tool call is not part of the report: the
                # child wrote it while working, the parent wants the outcome.
                output.append({'type': 'message', 'role': 'assistant',
                               'content': [{'type': 'output_text', 'text': 'Checking the workspace.\n'}]})
            output.append({'type': 'function_call', 'call_id': f'{kind}-{index}',
                           'name': kind, 'arguments': json.dumps(payload)})
        send_response(self, body, {'status': 'completed', 'output': output})


def instructions(body):
    return body.get('instructions', '') + json.dumps(
        [item for item in body['input'] if item.get('role') in ('system', 'developer')],
        ensure_ascii=False)


def tool_names(body):
    return {tool.get('name') for tool in body.get('tools') or []}


def is_subagent(body):
    return 'You are a sub-agent' in instructions(body)


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


server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), API)
threading.Thread(target=server.serve_forever, daemon=True).start()
try:
    with tempfile.TemporaryDirectory(prefix='zagent-subagent-') as directory:
        env = {'PATH': '/usr/bin:/bin', 'HOME': directory, 'XDG_CONFIG_HOME': directory,
               'TERM': 'dumb', 'AI_URL': f'http://127.0.0.1:{server.server_port}/v1',
               'AI_MODEL': 'mock', 'AI_KEY': 'test', 'AI_MAX_ITERATIONS': '12'}
        state = trust_workspace(directory, env)

        result = subprocess.run([str(binary), 'Delegate the check'], cwd=directory, env=env,
                                input='', text=True, capture_output=True, timeout=120)
        assert result.returncode == 0, result.stderr

        assert len(requests) == 5, (len(requests), [is_subagent(body) for body in requests])
        parent = [body for body in requests if not is_subagent(body)]
        child = [body for body in requests if is_subagent(body)]
        assert len(parent) == 3 and len(child) == 2, (len(parent), len(child))

        # A task that says nothing is refused before any agent is started.
        empty = status_of(tool_output(parent[1], 'subagent-1'))
        assert empty[0] and 'must be non-empty' in empty[1], empty

        # The sub-agent gets its own prompt, its own scratch directory, and
        # none of the parent's conversation.
        handed_over = json.dumps(child[0]['input'], ensure_ascii=False)
        assert 'The workspace is empty' in handed_over, handed_over
        assert 'Delegate the check' not in handed_over, handed_over
        assert scratch_of(child[0]) != scratch_of(parent[0]), (scratch_of(child[0]), scratch_of(parent[0]))
        assert child_scratch_live and all(child_scratch_live), child_scratch_live

        # Both prompts name the machine they run on, read once at startup and
        # inherited by the agent started from it.
        for body in (parent[0], child[0]):
            assert re.search(r'Host system: .+ \(.+\), ', instructions(body)), instructions(body)

        # It is not offered the tools that belong to the agent on the terminal.
        assert tool_names(child[0]).isdisjoint(
            {'ask_user', 'announce_task', 'subagent', 'subagent_stop', 'plan', 'remember'}), tool_names(child[0])
        assert {'bash', 'read', 'write', 'apply_patch'} <= tool_names(child[0]), tool_names(child[0])

        # Its own tools really ran, and its progress never reached the parent's
        # conversation: only the report did.
        ran = status_of(tool_output(child[1], 'bash-3'))
        assert not ran[0] and 'child ran a tool' in ran[1], ran
        report = status_of(tool_output(parent[2], 'subagent-2'))
        assert not report[0], report
        assert 'Sub-agent report' in report[1], report
        assert 'Ran bash' in report[1] and 'child ran a tool' not in report[1], report
        assert 'Checking the workspace' not in report[1], report

        # The parent owns the session: the sub-agent starts none of its own.
        sessions = list((state / 'sessions').glob('*.json'))
        assert len(sessions) == 1, sessions
        saved = json.loads(sessions[0].read_text())
        assert saved['plan'] == [], saved['plan']
        assert all(message['role'] != 'assistant' or 'Ran bash' not in (message.get('content') or '')
                   for message in saved['messages']), saved['messages']

        # The sub-agent's scratch directory is gone with its agent.
        assert not Path(scratch_of(child[0])).exists(), 'the child scratch outlived the child'

        # The caller's own answer is what the terminal shows.
        assert 'Delegation done.' in result.stdout, result.stdout
        assert 'Ran bash' not in result.stdout, result.stdout
        print('PASS: sub-agent runs its own turn, keeps the caller session and reports back')
finally:
    server.shutdown()
    server.server_close()
