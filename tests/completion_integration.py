#!/usr/bin/env python3
"""A task must not exit successfully when its completion check rejects it."""
import http.server
import json
from pathlib import Path
import subprocess
import tempfile
import threading

binary = Path(__file__).resolve().parents[1] / 'zig-out/bin/zagent'
scenario = {'verdict': None, 'checks': 0, 'rounds': 0, 'judge_replies': []}
judge_prompts = []

class API(http.server.BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass

    def reply(self, payload):
        data = json.dumps(payload).encode()
        self.send_response(200)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers['Content-Length'])))
        assert self.path == '/v1/responses' and 'messages' not in body
        if not body.get('tools'):
            scenario['checks'] += 1
            judge_prompts.append(body['input'][1]['content'])
            # A canned reply stands in for a check that fails outright: a
            # truncated response, or an HTTP error.
            if scenario['judge_replies']:
                return self.reply(scenario['judge_replies'].pop(0))
            content = scenario['verdict']
            return self.reply({'status': 'completed', 'output': [
                {'type': 'message', 'role': 'assistant',
                 'content': [{'type': 'output_text', 'text': content}]}]})
        answered = sum(m.get('type') == 'function_call_output' for m in body['input'])
        if answered < scenario['rounds'] or answered == 0:
            command = 'printf task-evidence' if scenario['rounds'] == 0 else f'printf round-{answered}-' + 'x' * 400
            return self.reply({'status': 'completed', 'output': [
                {'type': 'function_call', 'call_id': f'probe-{answered}', 'name': 'shell',
                 'arguments': json.dumps({'command': command})}]})
        return self.reply({'status': 'completed', 'output': [
            {'type': 'message', 'role': 'assistant',
             'content': [{'type': 'output_text', 'text': 'Candidate answer'}]}]})

server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), API)
threading.Thread(target=server.serve_forever, daemon=True).start()
try:
    with tempfile.TemporaryDirectory(prefix='zagent-completion-') as directory:
        env = {'PATH': '/usr/bin:/bin', 'HOME': directory, 'XDG_CONFIG_HOME': directory,
               'AI_URL': f'http://127.0.0.1:{server.server_port}/v1', 'AI_MODEL': 'mock',
               'AI_KEY': 'local-test', 'AI_MAX_ITERATIONS': '5', 'AI_MAX_VERIFICATIONS': '1'}
        for verdict, expected_ok in [
            (json.dumps({'complete': True, 'reason': 'Verified evidence'}), True),
            (json.dumps({'complete': False, 'reason': 'Missing behavior', 'next_step': 'Implement it'}), False),
            ('unreadable verdict', False),
        ]:
            scenario.update(verdict=verdict, checks=0, rounds=0)
            result = subprocess.run([str(binary), 'Perform the task'], cwd=directory, env=env,
                                    capture_output=True, text=True, timeout=30)
            assert scenario['checks'] == 1, result.stderr
            assert (result.returncode == 0) == expected_ok, result.stderr
            if not expected_ok:
                assert 'CompletionUnverified' in result.stderr, result.stderr

        # A turn whose summary exceeds the judge's budget must still show the
        # judge how it ended. When the opening work was kept and the tail
        # dropped, the answer never reached the check, finished work was
        # rejected, and the run ended with CompletionUnverified.
        judge_prompts.clear()
        scenario.update(verdict=json.dumps({'complete': True, 'reason': 'Saw the answer'}),
                        checks=0, rounds=18)
        long_env = dict(env, AI_MAX_ITERATIONS='30')
        result = subprocess.run([str(binary), 'Perform the long task'], cwd=directory, env=long_env,
                                capture_output=True, text=True, timeout=120)
        assert scenario['checks'] == 1, result.stderr
        prompt = judge_prompts[0]
        assert 'answer: Candidate answer' in prompt, prompt[-500:]
        assert 'round-0-' not in prompt, prompt[:500]
        assert result.returncode == 0, result.stderr

        # One unusable reply from the judge says nothing about the work: a
        # check that was truncated must be asked again while budget lasts,
        # not turn a finished turn into CompletionUnverified.
        truncated = {'status': 'incomplete',
                     'incomplete_details': {'reason': 'max_output_tokens'}, 'output': []}
        scenario.update(verdict=json.dumps({'complete': True, 'reason': 'Readable now'}),
                        checks=0, rounds=0, judge_replies=[dict(truncated)])
        retry_env = dict(env, AI_MAX_VERIFICATIONS='2')
        result = subprocess.run([str(binary), 'Perform the task'], cwd=directory, env=retry_env,
                                capture_output=True, text=True, timeout=30)
        assert scenario['checks'] == 2, result.stderr
        assert result.returncode == 0, result.stderr
        assert 'CompletionUnverified' not in result.stderr, result.stderr

        # When every attempt fails, the run still ends unverified, on the same
        # bounded budget as a judge that keeps rejecting the work.
        scenario.update(verdict=json.dumps({'complete': True, 'reason': 'never asked'}),
                        checks=0, rounds=0, judge_replies=[dict(truncated), dict(truncated)])
        result = subprocess.run([str(binary), 'Perform the task'], cwd=directory, env=retry_env,
                                capture_output=True, text=True, timeout=30)
        assert scenario['checks'] == 2, result.stderr
        assert result.returncode != 0 and 'CompletionUnverified' in result.stderr, result.stderr
        print('PASS: accepted, rejected and invalid verdicts have correct exit status; '
              'a turn longer than the summary budget still shows its answer to the judge; '
              'an unusable verdict is retried before the run is called unverified')
finally:
    server.shutdown()
