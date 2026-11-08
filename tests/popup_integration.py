#!/usr/bin/env python3
"""Exercise prompt candidates and editing through a real terminal, without an API."""
import fcntl
import os
from pathlib import Path
import pty
import re
import select
import struct
import subprocess
import tempfile
import termios
import time

binary = Path(__file__).resolve().parents[1] / 'zig-out/bin/zagent'
ansi = re.compile(rb'\x1b(?:\[[0-?]*[ -/]*[@-~]|[78])')

with tempfile.TemporaryDirectory(prefix='zagent-popup-') as directory:
    root = Path(directory)
    (root / 'src').mkdir()
    (root / 'src/alpha.zig').write_text('')
    (root / 'src/中文 file.zig').write_text('')
    (root / 'node_modules').mkdir()
    (root / 'node_modules/hidden.zig').write_text('')
    master, slave = pty.openpty()
    fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack('HHHH', 12, 80, 0, 0))
    original = termios.tcgetattr(slave)
    env = dict(os.environ, HOME=directory, XDG_CONFIG_HOME=directory,
               TERM='xterm-256color', AI_KEY='test', AI_MODEL='popup-mock')
    process = subprocess.Popen([str(binary)], cwd=directory, env=env,
                               stdin=slave, stdout=slave, stderr=slave)
    transcript = bytearray()

    def read_until(expected, raw=False):
        deadline = time.monotonic() + 8
        while expected not in (transcript if raw else ansi.sub(b'', transcript)):
            assert time.monotonic() < deadline, transcript.decode(errors='replace')
            assert process.poll() is None, transcript.decode(errors='replace')
            if select.select([master], [], [], 0.1)[0]:
                transcript.extend(os.read(master, 65536))

    def send(keys, expected):
        transcript.clear()
        os.write(master, keys)
        read_until(expected)

    try:
        read_until('you ❯ '.encode())
        send(b'/', b'/help  Show this help')
        send(b'\x1b[B\r', 'you ❯ /clear'.encode())
        assert b'Conversation history cleared.' not in transcript
        send(b'\r', b'Conversation history cleared.')
        send('check @ALPHA'.encode(), b'@src/alpha.zig  File')
        send(b'\t', 'you ❯ check @src/alpha.zig'.encode())
        send(b'\x15$', b'Coming soon')
        transcript.clear()
        os.write(master, b'\x1b')
        read_until(b'\x1b8', raw=True)
        send(b'\x15@missing', b'No matching files')
        send(b'\x15@hidden', b'No matching files')
        send('\x15@中文'.encode(), '@src/中文 file.zig  File'.encode())
        send(b'\t', 'you ❯ @"src/中文 file.zig"'.encode())
        # Complete in the middle of a line and retain its suffix.
        send(b'\x15check @alpha tail\x1b[D\x1b[D\x1b[D\x1b[D\x1b[D', b'@src/alpha.zig  File')
        send(b'\t', 'you ❯ check @src/alpha.zig tail'.encode())
        send(b'\x05\x15/qu\t\r', b'Goodbye!')
        assert process.wait(timeout=5) == 0
        assert termios.tcgetattr(slave) == original
        print('PASS: command navigation, explicit submission, file search, CJK/spaces, suffix preservation, empty/reserved states and terminal restoration')
    finally:
        if process.poll() is None:
            process.kill()
            process.wait()
        os.close(master)
        os.close(slave)
