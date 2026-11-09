#!/usr/bin/env python3
"""A task must not exit successfully when its completion check rejects it."""
from mock_api import send_response, handle_planning

import http.server
import json
from pathlib import Path
import subprocess
import tempfile
import threading

binary = Path(__file__).resolve().parents[1] / 'zig-out/bin/zagent'
scenario = {'verdict': None, 'checks': 0, 'rounds': 0, 'judge_replies': [],
            'require': None, 'command': None}
judge_prompts = []

class API(http.server.BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass

    def reply(self, payload):
        send_response(self, self.request_body, payload)

    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers['Content-Length'])))
        self.request_body = body
        if handle_planning(self, body):
            return
        assert self.path == '/v1/responses' and 'messages' not in body
        if not body.get('tools'):
            scenario['checks'] += 1
            judge_prompts.append(body['input'][1]['content'])
            # A canned reply stands in for a check that fails outright: a
            # truncated response, or an HTTP error.
            if scenario['judge_replies']:
                return self.reply(scenario['judge_replies'].pop(0))
            # A check whose evidence is the tail of a tool result: it answers
            # "complete" only when the summary it was given contains the line
            # that proves the work is done.
            if scenario['require'] is not None:
                seen = scenario['require'] in body['input'][1]['content']
                verdict = {'complete': seen,
                           'reason': 'The test result is in the summary.' if seen
                                     else 'The summary does not contain the test result.',
                           'next_step': None if seen else 'Run the tests and show the result.'}
                return self.reply({'status': 'completed', 'output': [
                    {'type': 'message', 'role': 'assistant',
                     'content': [{'type': 'output_text', 'text': json.dumps(verdict)}]}]})
            content = scenario['verdict']
            return self.reply({'status': 'completed', 'output': [
                {'type': 'message', 'role': 'assistant',
                 'content': [{'type': 'output_text', 'text': content}]}]})
        answered = sum(m.get('type') == 'function_call_output' for m in body['input'])
        if answered < scenario['rounds'] or answered == 0:
            if scenario['command'] is not None:
                command = scenario['command']
            elif scenario['rounds'] == 0:
                command = 'printf task-evidence'
            else:
                command = f'printf round-{answered}-' + 'x' * 400
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
               'AI_KEY': 'local-test', 'AI_MAX_ITERATIONS': '5', 'AI_MAX_VERIFICATIONS': '1',
               'AI_MEMORY': '0', 'AI_COMPACT_THRESHOLD': '0'}
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
            if 'Missing behavior' in verdict:
                # The final rejection must not run an extra, uncheckable
                # repair round (which used to print a second answer).
                assert result.stdout.count('Candidate answer') == 1, result.stdout
                assert 'Next step: Implement it' in result.stderr, result.stderr
                assert 'AI_MAX_VERIFICATIONS' in result.stderr, result.stderr

        # The default three-check budget permits two repair rounds, not a
        # third repair after the final rejection with no checks left.
        scenario.update(verdict=json.dumps({'complete': False, 'reason': 'Still missing',
                                           'next_step': 'Implement the missing behavior'}),
                        checks=0, rounds=0)
        result = subprocess.run([str(binary), 'Perform the task'], cwd=directory,
                                env=dict(env, AI_MAX_VERIFICATIONS='3'),
                                capture_output=True, text=True, timeout=30)
        assert scenario['checks'] == 3, result.stderr
        assert result.stdout.count('Candidate answer') == 3, result.stdout
        assert result.returncode != 0 and 'CompletionUnverified' in result.stderr, result.stderr
        assert 'Next step: Implement the missing behavior' in result.stderr, result.stderr

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

        # A finished task must pass the check on the evidence it produced. The
        # proof here is the last line of a long test run, which the summary has
        # to carry: keeping only the head of a result shows the setup and hides
        # the verdict, so genuinely finished work is rejected.
        scenario.update(verdict=None, checks=0, rounds=0, judge_replies=[],
                        require='42 tests, 0 failures',
                        # The proof is produced by the command, not spelled in
                        # it, so an echoed command cannot stand in for a result.
                        command="N=42; R=0; printf 'running the suite...\\n'; "
                                "head -c 600 /dev/zero | tr '\\0' x; "
                                "printf '\\n%s tests, %s failures\\n' \"$N\" \"$R\"")
        result = subprocess.run([str(binary), 'Run the tests'], cwd=directory, env=env,
                                capture_output=True, text=True, timeout=60)
        assert scenario['checks'] == 1, result.stderr
        assert '42 tests, 0 failures' in judge_prompts[-1], judge_prompts[-1]
        assert result.returncode == 0, result.stderr
        print('PASS: accepted, rejected and invalid verdicts have correct exit status; '
              'a turn longer than the summary budget still shows its answer to the judge; '
              'an unusable verdict is retried before the run is called unverified; '
              'a long tool result keeps the tail that proves the work is done')
finally:
    server.shutdown()
