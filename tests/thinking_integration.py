#!/usr/bin/env python3
"""The chain of thought scrolls in a panel above the prompt, then folds away.

The reasoning is streamed as `response.reasoning_text.delta` events. It must be
drawn in the panel the full-screen layout keeps above the prompt, must outlive
the start of the answer by a few seconds, and must not join the conversation:
the completed duration stays in the status bar, never in the conversation.
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

from mock_api import trust_workspace

binary = Path(__file__).resolve().parents[1] / 'zig-out/bin/zagent'
ansi = re.compile(rb'\x1b(?:\[[0-?]*[ -/]*[@-~]|[78])')

reasoning = ['Reading the workspace. ', 'It holds two files. ', 'Name both of them.']
# The answer is streamed one line at a time and slowly on purpose: the panel is
# meant to outlive the start of the answer, so the turn must still be writing
# when its delay is up.
answer_chunks = ['Both files ', 'are there:\n', 'alpha.zig and ', 'beta.zig.\n',
                 'Nothing else ', 'is in it.\n']
answer = ''.join(answer_chunks)
first_answer_at = None
second_answer = 'Second answer, no thinking this time.'
turns = 0


class API(http.server.BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass

    def do_POST(self):
        global turns, first_answer_at
        body = json.loads(self.rfile.read(int(self.headers['Content-Length'])))
        turns += 1
        thinking = turns == 1
        text = answer if thinking else second_answer
        assert body.get('stream') is True
        self.send_response(200)
        self.send_header('Content-Type', 'text/event-stream')
        self.end_headers()

        def emit(event):
            self.wfile.write(f'data: {json.dumps(event)}\n\n'.encode())
            self.wfile.flush()

        # The panel is painted by the foreground on its next wake-up, so the
        # deltas are spaced: a burst that arrives in one frame would be folded
        # into its one line before it was ever drawn.
        if thinking:
            for chunk in reasoning:
                emit({'type': 'response.reasoning_text.delta', 'delta': chunk, 'item_id': 'rs_1'})
                time.sleep(0.4)
            for chunk in answer_chunks:
                if first_answer_at is None:
                    first_answer_at = time.monotonic()
                emit({'type': 'response.output_text.delta', 'delta': chunk})
                time.sleep(0.7)
        else:
            emit({'type': 'response.output_text.delta', 'delta': text})
        output = [{'type': 'message', 'role': 'assistant',
                   'content': [{'type': 'output_text', 'text': text}]}]
        if thinking:
            output.insert(0, {'type': 'reasoning', 'id': 'rs_1',
                              'content': [{'type': 'reasoning_text', 'text': ''.join(reasoning)}]})
        emit({'type': 'response.completed',
              'response': {'status': 'completed', 'output': output}})


server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), API)
threading.Thread(target=server.serve_forever, daemon=True).start()
try:
    with tempfile.TemporaryDirectory(prefix='zagent-thinking-') as directory:
        Path(directory, 'alpha.zig').write_text('const a = 1;\n')
        Path(directory, 'beta.zig').write_text('const b = 2;\n')
        env = dict(PATH='/usr/bin:/bin', HOME=directory, XDG_CONFIG_HOME=directory,
                   TERM='xterm-256color', AI_KEY='test', AI_MODEL='thinking-mock',
                   AI_URL=f'http://127.0.0.1:{server.server_port}/v1')
        trust_workspace(directory, env)
        master, slave = pty.openpty()
        # 24 rows: the log keeps the rest, the status line one and the panel one.
        fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack('HHHH', 24, 80, 0, 0))
        original = termios.tcgetattr(slave)
        process = subprocess.Popen([str(binary)], cwd=directory, env=env,
                                   stdin=slave, stdout=slave, stderr=slave)
        transcript = bytearray()

        def until(expected, timeout=15):
            deadline = time.monotonic() + timeout
            while expected not in ansi.sub(b'', transcript):
                assert time.monotonic() < deadline, transcript.decode(errors='replace')
                assert process.poll() is None, transcript.decode(errors='replace')
                if select.select([master], [], [], 0.1)[0]:
                    transcript.extend(os.read(master, 65536))

        try:
            until('❯ '.encode())
            os.write(master, b'list the files\r')

            # The answer's first line is written while the panel is still open.
            until(answer_chunks[0].encode())
            during = ansi.sub(b'', bytes(transcript))
            assert reasoning[-1].strip().encode() in during, during
            until('✻ Thought for'.encode())
            reported_at = time.monotonic()
            assert reported_at - first_answer_at < 2.5, 'duration was not shown when thinking ended'
            # With the one-row panel open, the status bar is on row 22.
            raw = bytes(transcript)
            duration_at = raw.index('✻ Thought for'.encode())
            positions = re.findall(rb'\x1b\[(\d+)(?:;\d+)?H', raw[:duration_at])
            assert positions[-1] == b'22', 'duration missing from status bar'

            plain = ansi.sub(b'', bytes(transcript))
            folded_index = plain.index('✻ Thought for'.encode())
            # The reasoning was on the screen while it was being written, a
            # piece at a time, and all of it before the fold. The panel shows
            # the newest row, so each piece is overwritten by the next one.
            for chunk in reasoning:
                assert chunk.strip().encode() in plain[:folded_index], plain[:folded_index]
            assert b'Assistant' in plain, plain
            # The panel still lingers after the duration appears in the status.
            time.sleep(3.2)
            while select.select([master], [], [], 0)[0]:
                transcript.extend(os.read(master, 65536))
            mark_closed = len(transcript)

            # The rest of the answer keeps arriving after the panel has gone.
            until(b'is in it.')
            plain = ansi.sub(b'', bytes(transcript))
            assert plain.index(b'is in it.') > plain.index('✻ Thought for'.encode()), plain
            after_close = ansi.sub(b'', bytes(transcript[mark_closed:]))
            for chunk in reasoning:
                assert chunk.strip().encode() not in after_close, after_close

            # A response that narrates nothing opens no panel and leaves no
            # summary line behind.
            mark = len(transcript)
            time.sleep(0.3)
            os.write(master, b'and again\r')
            deadline = time.monotonic() + 15
            while second_answer.encode() not in ansi.sub(b'', bytes(transcript[mark:])):
                assert time.monotonic() < deadline, transcript.decode(errors='replace')
                assert process.poll() is None, transcript.decode(errors='replace')
                if select.select([master], [], [], 0.1)[0]:
                    transcript.extend(os.read(master, 65536))
            after = ansi.sub(b'', bytes(transcript[mark:]))
            assert '✻ Thought for'.encode() not in after, after

            os.write(master, b'\x04')
            deadline = time.monotonic() + 10
            while process.poll() is None:
                assert time.monotonic() < deadline, transcript.decode(errors='replace')
                if select.select([master], [], [], 0.1)[0]:
                    transcript.extend(os.read(master, 65536))
            assert process.returncode == 0, transcript.decode(errors='replace')
            assert termios.tcgetattr(slave) == original, 'raw terminal was not restored'
        finally:
            if process.poll() is None:
                process.kill()
                process.wait()
            os.close(master)
            os.close(slave)
        print('PASS: thinking panel lingers; completed duration stays in the status bar')
finally:
    server.shutdown()
    server.server_close()
