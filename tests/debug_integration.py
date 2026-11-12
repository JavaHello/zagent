#!/usr/bin/env python3
"""`--debug` must record every step and render an HTML report of the run."""
import http.server
import json
from pathlib import Path
import shutil
import subprocess
import tempfile
import threading

from mock_api import send_response, trust_workspace

BINARY = Path(__file__).resolve().parents[1] / 'zig-out/bin/zagent'
ANSWER = 'DEBUG_REPORT_DONE'
CALL = ('bash', {'command': 'echo DEBUG_TOOL_OUTPUT "<b>bold</b>"'})

requests = []
fail_next = False


def payload(status='completed', output=None, error=None):
    return {'id': f'resp_{len(requests)}', 'object': 'response', 'status': status,
            'error': error, 'output': output or []}


class API(http.server.BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass

    def do_POST(self):
        global fail_next
        body = json.loads(self.rfile.read(int(self.headers['Content-Length'])))
        requests.append(body)
        assert self.path == '/v1/responses'
        if fail_next:
            fail_next = False
            data = json.dumps({'error': {'message': 'the model refused the request'}}).encode()
            self.send_response(500)
            self.send_header('Content-Type', 'application/json')
            self.send_header('Content-Length', str(len(data)))
            self.end_headers()
            self.wfile.write(data)
            return
        results = [m for m in body['input'] if m.get('type') == 'function_call_output']
        if not results:
            name, arguments = CALL
            output = [{'id': 'rs_1', 'type': 'reasoning', 'summary': [], 'encrypted_content': 'opaque'},
                      {'id': 'fc_1', 'type': 'function_call', 'status': 'completed', 'call_id': 'call_1',
                       'name': name, 'arguments': json.dumps(arguments)}]
        else:
            output = [{'id': 'msg_1', 'type': 'message', 'role': 'assistant', 'status': 'completed',
                       'content': [{'type': 'output_text', 'text': ANSWER, 'annotations': []}]}]
        send_response(self, body, payload(output=output))


def debug_files(directory):
    debug = directory / 'debug'
    assert debug.is_dir(), f'no debug directory under {directory}'
    traces = sorted(debug.glob('*.jsonl'))
    reports = sorted(debug.glob('*.html'))
    assert len(traces) == 1, traces
    assert len(reports) == 1, reports
    return traces[0], reports[0]


server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), API)
threading.Thread(target=server.serve_forever, daemon=True).start()
try:
    with tempfile.TemporaryDirectory(prefix='zagent-debug-') as temporary:
        root = Path(temporary)
        workspace = root / 'work'
        workspace.mkdir()
        env = {'PATH': '/usr/bin:/bin', 'HOME': str(root), 'XDG_CONFIG_HOME': str(root),
               'AI_URL': f'http://127.0.0.1:{server.server_port}/v1', 'AI_MODEL': 'mock',
               'AI_KEY': 'test'}
        state = trust_workspace(workspace, env)

        result = subprocess.run([str(BINARY), '--debug', 'Explain <the> run'],
                                cwd=workspace, env=env, capture_output=True, text=True, timeout=60)
        assert result.returncode == 0, result.stderr
        assert result.stdout == ANSWER + '\n', result.stdout
        assert 'Debug: recording' in result.stderr, result.stderr
        assert 'Debug: report ' in result.stderr, result.stderr

        trace_path, report_path = debug_files(state)
        events = [json.loads(line) for line in trace_path.read_text().splitlines()]
        kinds = [event['event'] for event in events]
        for kind in ('run', 'query', 'request', 'response', 'tool_call', 'tool_result', 'turn'):
            assert kind in kinds, (kind, kinds)
        assert kinds[0] == 'run' and kinds[-1] == 'turn', kinds
        assert [event['seq'] for event in events] == list(range(len(events)))

        run = events[0]
        assert run['model'] == 'mock' and run['workspace'] == str(workspace.resolve()), run
        assert any(event['event'] == 'query' and event['text'] == 'Explain <the> run' for event in events)

        sent = [event for event in events if event['event'] == 'request']
        received = [event for event in events if event['event'] == 'response']
        assert len(sent) == 2 and len(received) == 2, (len(sent), len(received))
        first = json.loads(sent[0]['body'])
        assert first['stream'] is True and first['model'] == 'mock', first
        assert first['input'][-1]['content'] == 'Explain <the> run', first['input'][-1]
        assert sent[0]['iter'] == 1 and sent[1]['iter'] == 2
        # The second request carries the tool result back to the model.
        second = json.loads(sent[1]['body'])
        outputs = [item for item in second['input'] if item.get('type') == 'function_call_output']
        assert outputs and 'DEBUG_TOOL_OUTPUT' in outputs[0]['output'], second['input']
        # The raw stream is kept as it arrived, not just the parsed reply.
        assert 'response.completed' in received[0]['raw'], received[0]['raw'][:200]
        assert received[0]['finish'] == 'tool_calls'
        assert received[1]['finish'] == 'stop' and received[1]['content'] == ANSWER

        call, = (event for event in events if event['event'] == 'tool_call')
        assert call['name'] == 'bash' and json.loads(call['args']) == CALL[1], call
        done, = (event for event in events if event['event'] == 'tool_result')
        assert done['name'] == 'bash' and done['call_id'] == call['call_id'], done
        assert not done['is_error'] and done['exit_code'] == 0, done
        assert 'DEBUG_TOOL_OUTPUT' in done['content'], done['content']

        html = report_path.read_text()
        assert html.startswith('<!doctype html>'), html[:40]
        assert html.count('<script') == 1, 'only the report\'s own script is markup'
        for needle in ('Explain &lt;the&gt; run', 'Request #1', 'Request #2', 'Response #1',
                       'Call bash', 'bash result', 'Turn finished', ANSWER):
            assert needle in html, (needle, html.count(needle))
        # Model output and tool output are data: they are escaped, never markup.
        assert '<b>bold</b>' not in html
        assert '&lt;b&gt;bold&lt;/b&gt;' in html

        # A report is rendered from the trace, so it can be rebuilt later.
        report_path.unlink()
        rebuilt = subprocess.run([str(BINARY), '--debug-report', str(trace_path)],
                                 cwd=workspace, env=env, capture_output=True, text=True, timeout=30)
        assert rebuilt.returncode == 0, rebuilt.stderr
        assert rebuilt.stdout.strip() == str(report_path), rebuilt.stdout
        assert report_path.read_text().startswith('<!doctype html>')

        # A failed request is a step too, with what the server said.
        fail_next = True
        failed = subprocess.run([str(BINARY), '--debug', 'Ask the impossible'],
                                cwd=workspace, env=env, capture_output=True, text=True, timeout=60)
        assert failed.returncode != 0, failed
        traces = sorted((state / 'debug').glob('*.jsonl'), key=lambda path: path.stat().st_mtime)
        assert len(traces) == 2, traces
        failed_events = [json.loads(line) for line in traces[-1].read_text().splitlines()]
        failures = [event for event in failed_events if event['event'] == 'failure']
        assert failures, [event['event'] for event in failed_events]
        assert 'the model refused the request' in failures[0]['message'], failures[0]
        assert 'the model refused the request' in failures[0]['raw'], failures[0]['raw']

        # AI_DEBUG turns the same recording on without the flag.
        env_debug = dict(env, AI_DEBUG='1')
        enabled = subprocess.run([str(BINARY), 'Explain again'], cwd=workspace, env=env_debug,
                                 capture_output=True, text=True, timeout=60)
        assert enabled.returncode == 0, enabled.stderr
        assert 'Debug: report ' in enabled.stderr, enabled.stderr
        assert len(list((state / 'debug').glob('*.html'))) == 3
    print('PASS: --debug records requests, responses, tool calls and results, and renders a report')
finally:
    server.shutdown()
    server.server_close()
