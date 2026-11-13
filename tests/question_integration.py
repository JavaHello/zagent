#!/usr/bin/env python3
"""A question owns the prompt rows: the form answers it, the input box does not.

One ask_user call carries two questions, drawn as horizontal tabs with only the
focused question's rows visible. Tab and Shift+Tab walk between them — an answer
given to an earlier question can be changed before the form is submitted. The last row of
each question is free text, and nothing typed at the form reaches the running
task as guidance. The strip ends on a Confirm tab, which either submits the
answers or takes words of the user's own to send with them, and every answer
lands there instead of being sent off on the last Enter. Esc in the free-text
row steps back to the options; Esc at the questions cancels them and stops the
run, and Ctrl+C is not a way out of a question at all.
"""
import fcntl
import http.server
import json
import os
from pathlib import Path
import pty
import re
import select
import struct
import subprocess
import tempfile
import termios
import threading
import time
from mock_api import send_response, trust_workspace

answers = []
requests = []
recorded = set()


class API(http.server.BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass

    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers['Content-Length'])))
        previous = len([r for r in requests if r.get('tools')])
        requests.append(body)
        results = [m for m in body['input'] if m.get('type') == 'function_call_output']
        turn = previous + 1
        if not body.get('tools'):
            output = [{'type': 'message', 'role': 'assistant',
                       'content': [{'type': 'output_text', 'text': '{}'}]}]
        elif turn == 1:
            output = [
                {'type': 'function_call', 'call_id': 'both', 'name': 'ask_user',
                 'arguments': json.dumps({'questions': [
                     {'question': 'First question?', 'options': [
                         {'label': 'Alpha'}, {'label': 'Beta', 'recommended': True}]},
                     {'question': 'Second question?', 'options': [
                         {'label': 'Gamma'}, {'label': 'Delta', 'recommended': True}]},
                 ]})},
            ]
        elif turn == 3:
            output = [{'type': 'function_call', 'call_id': 'only', 'name': 'ask_user',
                       'arguments': json.dumps({'questions': [
                           {'question': 'Submit this one?', 'options': [
                               {'label': 'Alpha'}, {'label': 'Beta', 'recommended': True}]}]})}]
        elif turn == 5:
            output = [{'type': 'function_call', 'call_id': 'cancel', 'name': 'ask_user',
                       'arguments': json.dumps({'questions': [
                           {'question': 'Cancel this one?', 'options': [
                               {'label': 'Alpha'}, {'label': 'Beta', 'recommended': True}]}]})}]
        else:
            for result in results:
                # Every earlier result is replayed on each request; only the
                # new one belongs to this turn.
                if result['call_id'] in recorded:
                    continue
                recorded.add(result['call_id'])
                answers.append((result['call_id'], result['output']))
            output = [{'type': 'message', 'role': 'assistant',
                       'content': [{'type': 'output_text', 'text': 'Turn complete'}]}]
        send_response(self, body, {'status': 'completed', 'output': output})


server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), API)
threading.Thread(target=server.serve_forever, daemon=True).start()
binary = Path(__file__).resolve().parents[1] / 'zig-out/bin/zagent'
ansi = re.compile(rb'\x1b(?:\[[0-?]*[ -/]*[@-~]|[78])')
try:
    with tempfile.TemporaryDirectory(prefix='zagent-question-') as directory:
        env = dict(PATH='/usr/bin:/bin', HOME=directory, XDG_CONFIG_HOME=directory,
                   TERM='xterm-256color', AI_KEY='test', AI_MODEL='question-mock',
                   AI_URL=f'http://127.0.0.1:{server.server_port}/v1')
        trust_workspace(directory, env)
        master, slave = pty.openpty()
        fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack('HHHH', 24, 100, 0, 0))
        original = termios.tcgetattr(slave)
        process = subprocess.Popen([str(binary)], cwd=directory, env=env,
                                   stdin=slave, stdout=slave, stderr=slave)
        transcript = bytearray()

        def clean():
            return ansi.sub(b'', transcript)

        def until(predicate, expected):
            deadline = time.monotonic() + 12
            while not predicate():
                assert time.monotonic() < deadline, expected.decode() + '\n' + transcript.decode(errors='replace')
                assert process.poll() is None, transcript.decode(errors='replace')
                if select.select([master], [], [], 0.05)[0]:
                    transcript.extend(os.read(master, 65536))

        def drawn(text, mark=0):
            # A drawn option row, unlike the tool-call announcement above it,
            # which carries the labels as JSON.
            return text.encode() in ansi.sub(b'', transcript[mark:])

        def focused_tab(label, mark=0):
            # Focus is cyan and underlined: a number for a question, the word
            # itself for the confirmation, with a check once it is ready.
            return any(f'\x1b[1;36m\x1b[4m {status} {label} '.encode() in transcript[mark:]
                       for status in ('·', '✓'))

        def since(mark):
            # `mark` counts raw bytes; the text since it is what the assertions
            # read, with the cursor movement stripped.
            return ansi.sub(b'', bytes(transcript[mark:]))

        def settle(seconds=0.1):
            time.sleep(seconds)

        try:
            until(lambda: clean().count(b'\xe2\x9d\xaf ') > 0, b'the prompt')

            # Turn one: two questions in one call, drawn as one form. The
            # first question has the keyboard: stray typing belongs to it, and
            # Enter answers it with the recommendation.
            os.write(master, b'ask me twice\r')
            until(lambda: drawn('1/2 First question?'), b'the form')
            until(lambda: drawn('1) Alpha'), b'first question')
            settle()
            os.write(master, b'zz')
            os.write(master, b'\r')

            # The second question takes the keyboard; focus is cyan/underlined.
            mark = len(transcript)
            until(lambda: drawn('1) Gamma', mark), b'second question')
            until(lambda: focused_tab('2', mark), b'the second tab')

            # Shift+Tab walks back to the question already answered: the wrong
            # answer can still be changed, and after an arrow key the answer is
            # the other option. That is the whole point of one form.
            settle()
            mark = len(transcript)
            os.write(master, b'\x1b[Z')
            until(lambda: drawn('1) Alpha', mark), b'the first question again')
            until(lambda: focused_tab('1', mark), b'the first tab')
            until(lambda: drawn('1/2 First question?  \u2192 Beta', mark), b'the first answer')
            settle()
            os.write(master, b'\x1b[A\r')
            mark = len(transcript)
            until(lambda: drawn('1) Gamma', mark), b'the second question again')
            until(lambda: focused_tab('2', mark), b'the second tab again')

            # The second question's last row types an answer.
            settle()
            os.write(master, b'3\r')
            until(lambda: drawn('choice', mark), b'the free-text prompt')
            if b'\x1b[6n' in transcript[mark:]:
                os.write(master, b'\x1b[1;1R')
            # Esc in the free-text row goes back to the options: it is neither a
            # dismissal nor an interruption of the run.
            mark = len(transcript)
            os.write(master, b'\x1b')
            until(lambda: drawn('1) Gamma', mark), b'the options again')
            settle()
            assert b'interrupted' not in clean(), transcript
            os.write(master, b'3\r')
            until(lambda: drawn('choice', mark), b'the free-text row again')
            if b'\x1b[6n' in transcript[mark:]:
                os.write(master, b'\x1b[1;1R')
            os.write(master, b'my own words\r')

            # The last answer lands on the confirmation instead of sending the
            # answers off: the strip ends on it, and its two rows say what can
            # be done there.
            mark = len(transcript)
            until(lambda: drawn('1) Submit', mark), b'the confirmation')
            until(lambda: drawn('2) Supplement', mark), b'the supplement row')
            until(lambda: focused_tab('Confirm', mark), b'the confirmation tab')
            # An answered question is checked in green beside its number.
            until(lambda: b'\x1b[32m \xe2\x9c\x93 1 ' in transcript[mark:], b'the answered tab')

            # Supplement asks for words to send with the answers, and they are
            # submitted with them rather than answering a question.
            settle()
            os.write(master, b'2\r')
            mark = len(transcript)
            until(lambda: drawn('choice', mark), b'the supplement prompt')
            if b'\x1b[6n' in transcript[mark:]:
                os.write(master, b'\x1b[1;1R')
            os.write(master, b'and mind the tests\r')
            until(lambda: b'Turn complete' in clean(), b'the answer')
            until(lambda: len(answers) == 1, b'the tool result')

            # One call carries both answers: each line names the question it
            # settles, so the model knows which decision is which, and the words
            # typed at the confirmation come after them.
            assert answers[0][0] == 'both', answers
            assert 'First question? \u2192 User selected: Alpha' in answers[0][1], answers
            assert 'Second question? \u2192 ' in answers[0][1], answers
            assert 'answered: my own words' in answers[0][1], answers
            assert 'The user added: and mind the tests' in answers[0][1], answers
            # Nothing typed at a menu is guidance for the running task.
            assert b'Input sent to the running task' not in clean(), transcript
            # Both tool results reached the model in the same request.
            assert len([r for r in requests if r.get('tools')]) == 2, requests

            # Turn two: a single question is a form of one, and Submit sends it
            # without words of the user's own.
            mark = len(transcript)
            os.write(master, b'submit please\r')
            until(lambda: drawn('Submit this one?', mark), b'the single question')
            os.write(master, b'\r')
            mark = len(transcript)
            until(lambda: drawn('1) Submit', mark), b'the confirmation of it')
            until(lambda: focused_tab('Confirm', mark), b'the confirmation tab of it')
            settle()
            os.write(master, b'\r')
            until(lambda: len(answers) == 2, b'the submitted result')
            assert answers[1][0] == 'only', answers
            assert 'User selected the recommended option: Beta' in answers[1][1], answers
            assert 'The user added' not in answers[1][1], answers

            # Turn three: Ctrl+C is not a way out of a question, and Esc cancels
            # the questions and stops the run with them.
            mark = len(transcript)
            os.write(master, b'cancel please\r')
            until(lambda: drawn('Cancel this one?', mark), b'the cancelled question')
            settle()
            os.write(master, b'\x03')
            settle(0.3)
            assert len(answers) == 2, 'Ctrl+C must not answer or dismiss a question'
            assert process.poll() is None, transcript
            mark = len(transcript)
            os.write(master, b'\x1b')
            until(lambda: b'Task interrupted (Esc)' in since(mark), b'the stop')
            until(lambda: b'\xe2\x9d\xaf ' in since(mark), b'the prompt again')
            settle(0.3)
            # Nothing was answered: the model never sees the cancelled question,
            # and the session carries on where the run stopped.
            assert len(answers) == 2, answers
            assert process.poll() is None, transcript

            os.write(master, b'/quit\r\r')
            until(lambda: b'Goodbye!' in transcript, b'the exit')
            assert process.wait(timeout=5) == 0
            assert termios.tcgetattr(slave) == original, 'raw terminal was not restored'
            print('PASS: questions share the prompt rows, one form holds them all, Tab and '
                  'Shift+Tab revise an answer already given, the last row types an answer or '
                  'steps back to the options, the Confirm tab submits the answers or takes '
                  'words to add, Ctrl+C is ignored, and Esc cancels the questions and stops '
                  'the run')
        finally:
            if process.poll() is None:
                process.kill()
                process.wait()
            os.close(master)
            os.close(slave)
finally:
    server.shutdown()
