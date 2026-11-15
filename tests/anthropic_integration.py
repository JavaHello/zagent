#!/usr/bin/env python3
"""The Messages API is spoken over /messages, with blocks and a system field."""
import http.server
import json
from pathlib import Path
import subprocess
import tempfile
import threading

from mock_api import trust_workspace

binary = Path(__file__).resolve().parents[1] / 'zig-out/bin/zagent'
requests = []
listed = []
# What the first answer of a run is: plain text, a tool call, or a thought.
scenario = 'text'


def sse(events):
    """One SSE frame per event, the way the Messages API streams."""
    return ''.join(
        f'event: {event["type"]}\ndata: {json.dumps(event)}\n\n' for event in events).encode()


def reply(handler, events):
    data = sse(events)
    handler.send_response(200)
    handler.send_header('Content-Type', 'text/event-stream')
    handler.send_header('Content-Length', str(len(data)))
    handler.end_headers()
    handler.wfile.write(data)


def start(usage):
    return {'type': 'message_start', 'message': {
        'id': 'msg_1', 'role': 'assistant', 'content': [], 'model': 'claude-sonnet-4-5',
        'usage': usage}}


def text_start(index=0):
    return {'type': 'content_block_start', 'index': index,
            'content_block': {'type': 'text', 'text': ''}}


def text_delta(index, text):
    return {'type': 'content_block_delta', 'index': index,
            'delta': {'type': 'text_delta', 'text': text}}


def text_answer(text, input_tokens=100, cache_read=50, output_tokens=20):
    return [
        start({'input_tokens': input_tokens, 'output_tokens': 1,
               'cache_read_input_tokens': cache_read,
               'cache_creation_input_tokens': 0}),
        text_start(),
        text_delta(0, text[:len(text) // 2]),
        text_delta(0, text[len(text) // 2:]),
        {'type': 'content_block_stop', 'index': 0},
        {'type': 'message_delta', 'delta': {'stop_reason': 'end_turn'},
         'usage': {'output_tokens': output_tokens}},
        {'type': 'message_stop'},
    ]


def tool_call():
    """A thought, then a call whose arguments arrive as partial JSON."""
    return [
        start({'input_tokens': 40, 'output_tokens': 1}),
        {'type': 'content_block_start', 'index': 0,
         'content_block': {'type': 'thinking', 'thinking': ''}},
        {'type': 'content_block_delta', 'index': 0,
         'delta': {'type': 'thinking_delta', 'thinking': 'weigh it'}},
        {'type': 'content_block_delta', 'index': 0,
         'delta': {'type': 'signature_delta', 'signature': 'sig-xyz'}},
        {'type': 'content_block_stop', 'index': 0},
        text_start(1),
        text_delta(1, 'Running it.'),
        {'type': 'content_block_stop', 'index': 1},
        {'type': 'content_block_start', 'index': 2,
         'content_block': {'type': 'tool_use', 'id': 'toolu_1', 'name': 'bash',
                           'input': {}}},
        {'type': 'content_block_delta', 'index': 2,
         'delta': {'type': 'input_json_delta', 'partial_json': '{"command":'}},
        {'type': 'content_block_delta', 'index': 2,
         'delta': {'type': 'input_json_delta', 'partial_json': ' "printf hi"}'}},
        {'type': 'content_block_stop', 'index': 2},
        {'type': 'message_delta', 'delta': {'stop_reason': 'tool_use'},
         'usage': {'output_tokens': 12}},
        {'type': 'message_stop'},
    ]


class API(http.server.BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass

    def do_GET(self):
        # `zagent models` lists <AI_URL>/models with the same credential.
        listed.append({'path': self.path, 'headers': dict(self.headers)})
        data = json.dumps({'data': [{'id': 'claude-sonnet-4-5'}], 'has_more': False}).encode()
        self.send_response(200)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers['Content-Length'])))
        requests.append({'path': self.path, 'headers': dict(self.headers), 'body': body})
        if len(requests) == 1 and scenario != 'text':
            reply(self, tool_call())
        else:
            reply(self, text_answer('Done.'))


server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), API)
threading.Thread(target=server.serve_forever, daemon=True).start()
try:
    with tempfile.TemporaryDirectory(prefix='zagent-messages-') as directory:
        env = {'PATH': '/usr/bin:/bin', 'HOME': directory, 'XDG_CONFIG_HOME': directory,
               'AI_PROVIDER': 'anthropic-compatible',
               'AI_URL': f'http://127.0.0.1:{server.server_port}/v1',
               'AI_MODEL': 'claude-sonnet-4-5', 'AI_KEY': 'sk-ant-test'}
        trust_workspace(directory, env)

        # One plain answer, streamed as content blocks.
        result = subprocess.run([str(binary), 'Answer'], cwd=directory, env=env,
                                capture_output=True, text=True, timeout=20)
        assert result.returncode == 0, result.stderr
        assert result.stdout == 'Done.\n', repr(result.stdout)
        assert len(requests) == 1, requests
        sent = requests[0]
        assert sent['path'] == '/v1/messages', sent['path']
        assert sent['headers']['x-api-key'] == 'sk-ant-test', sent['headers']
        assert sent['headers']['anthropic-version'] == '2023-06-01', sent['headers']
        assert 'authorization' not in {k.lower() for k in sent['headers']}, sent['headers']
        body = sent['body']
        assert body['model'] == 'claude-sonnet-4-5', body
        assert body['stream'] is True, body
        assert isinstance(body['max_tokens'], int) and body['max_tokens'] > 0, body
        # No Responses members, and no thinking unless it was asked for.
        for absent in ('input', 'max_output_tokens', 'store', 'thinking', 'reasoning'):
            assert absent not in body, (absent, body)
        assert body['messages'][0]['role'] == 'user', body['messages']
        assert body['system'].startswith('You are zagent'), body['system']
        tools = {tool['name']: tool for tool in body['tools']}
        assert 'bash' in tools and 'read' in tools, sorted(tools)
        assert tools['read']['input_schema']['type'] == 'object', tools['read']
        assert 'parameters' not in tools['read'] and 'strict' not in tools['read'], tools['read']
        # Cache reads count inside the prompt, as the summary line promises.
        assert 'in 150 (cached 50, reported; cache reports 1/1)' in result.stderr, result.stderr
        assert 'total 170 tokens' in result.stderr, result.stderr

        # The administrative listing uses the same host and credential.
        result = subprocess.run([str(binary), 'models'], cwd=directory, env=env,
                                capture_output=True, text=True, timeout=20)
        assert result.returncode == 0, result.stderr
        assert 'claude-sonnet-4-5' in result.stdout, result.stdout
        assert listed[0]['path'] == '/v1/models', listed[0]['path']
        assert listed[0]['headers']['x-api-key'] == 'sk-ant-test', listed[0]['headers']
        assert listed[0]['headers']['anthropic-version'] == '2023-06-01', listed[0]['headers']

        # Asked to think, the request reserves a budget for it; the API has no
        # dial of its own, so this is the one shape AI_THINKING takes here.
        requests.clear()
        result = subprocess.run([str(binary), 'Answer'], cwd=directory,
                                env={**env, 'AI_THINKING': 'enabled'},
                                capture_output=True, text=True, timeout=20)
        assert result.returncode == 0, result.stderr
        assert requests[0]['body']['thinking'] == {'type': 'enabled', 'budget_tokens': 4096}, \
            requests[0]['body']['thinking']

        # A tool call, and the result handed back as a user block.
        requests.clear()
        scenario = 'tool'
        result = subprocess.run([str(binary), 'Run the command then answer'], cwd=directory,
                                env=env, capture_output=True, text=True, timeout=20)
        assert result.returncode == 0, result.stderr
        assert 'Done.' in result.stdout, repr(result.stdout)
        assert len(requests) == 2, requests
        second = requests[1]['body']
        roles = [message['role'] for message in second['messages']]
        assert roles == ['user', 'assistant', 'user'], roles
        assistant = second['messages'][1]['content']
        # Thinking was not asked for, so the block the model sent is not replayed.
        assert [block['type'] for block in assistant] == ['text', 'tool_use'], assistant
        assert assistant[1]['id'] == 'toolu_1' and assistant[1]['name'] == 'bash', assistant
        assert assistant[1]['input'] == {'command': 'printf hi'}, assistant
        results = second['messages'][2]['content']
        assert len(results) == 1 and results[0]['type'] == 'tool_result', results
        assert results[0]['tool_use_id'] == 'toolu_1', results
        assert 'hi' in results[0]['content'], results
        assert 'is_error' not in results[0], results

        # With thinking asked for, the signed block travels back unchanged: the
        # API refuses a thinking conversation that lost it.
        requests.clear()
        scenario = 'thinking'
        result = subprocess.run([str(binary), 'Run the command then answer'], cwd=directory,
                                env={**env, 'AI_THINKING': 'enabled'},
                                capture_output=True, text=True, timeout=20)
        assert result.returncode == 0, result.stderr
        assert len(requests) == 2, requests
        second = requests[1]['body']
        assistant = second['messages'][1]['content']
        assert [block['type'] for block in assistant] == ['thinking', 'text', 'tool_use'], assistant
        assert assistant[0]['thinking'] == 'weigh it', assistant[0]
        assert assistant[0]['signature'] == 'sig-xyz', assistant[0]
        print('PASS: Messages requests use /messages and /models with x-api-key, a '
              'system field, input_schema tools and a thinking budget, and return '
              'tool results as user blocks with the signed thought intact')
finally:
    server.shutdown()
    server.server_close()
