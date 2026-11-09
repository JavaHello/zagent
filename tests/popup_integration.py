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
    state = root / 'state' / 'zagent'
    state.mkdir(parents=True)
    (state / 'history').write_text('older question\n/help\n/model\n')
    master, slave = pty.openpty()
    fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack('HHHH', 12, 80, 0, 0))
    original = termios.tcgetattr(slave)
    env = dict(os.environ, HOME=directory, XDG_CONFIG_HOME=directory,
               XDG_STATE_HOME=str(root / 'state'),
               TERM='xterm-256color', AI_KEY='test', AI_MODEL='popup-mock',
               AI_MEMORY='0', AI_COMPACT_THRESHOLD='0')
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
        read_until('❯ '.encode())
        assert b'\x1b[?1000h\x1b[?1006h' in transcript
        send(b'draft', '❯ draft'.encode())
        # Recalled slash commands must not capture arrows in a completion menu.
        send(b'\x1b[A', '❯ /model'.encode())
        assert b'Tab/Enter insert' not in transcript
        send(b'\x1b[A', '❯ /help'.encode())
        send(b'\x1b[A', '❯ older question'.encode())
        send(b'\x1b[B', '❯ /help'.encode())
        send(b'\x1b[B', '❯ /model'.encode())
        send(b'\x1b[B', '❯ draft'.encode())
        # Wheel reports scroll the transcript, never input history; both
        # directions work with the pointer over the bottom input row.
        send(b'\x1b[<64;10;12M', '❯ draft'.encode())
        assert b'\x1b[1;1H' in transcript  # log replay, not just input refresh
        send(b'\x1b[<65;10;12M', '❯ draft'.encode())
        # Clicks and releases are consumed without leaking coordinates.
        send(b'\x1b[<0;10;12M\x1b[<0;10;12m!', '❯ draft!'.encode())
        send(b'\x15', '❯ '.encode())
        send(b'/', b'/help  Show this help')
        # Scrolling must also leave an active completion selection intact.
        send(b'\x1b[<64;10;12M', b'/help  Show this help')
        send(b'\x1b[<65;10;12M', b'/help  Show this help')
        send(b'\x1b[B\r', '❯ /clear'.encode())
        assert b'Conversation history cleared.' not in transcript
        send(b'\r', b'Conversation history cleared.')
        # The command message precedes raw-mode setup for the next prompt.
        read_until(b'\x1b[?2004h', raw=True)
        send('check @ALPHA'.encode(), b'@src/alpha.zig  File')
        send(b'\t', '❯ check @src/alpha.zig'.encode())
        send(b'\x15$', b'Coming soon')
        transcript.clear()
        os.write(master, b'\x1b')
        read_until(b'\x1b8', raw=True)
        send(b'\x15@missing', b'No matching files')
        send(b'\x15@hidden', b'No matching files')
        send('\x15@中文'.encode(), '@src/中文 file.zig  File'.encode())
        send(b'\t', '❯ @"src/中文 file.zig"'.encode())
        # Complete in the middle of a line and retain its suffix.
        send(b'\x15check @alpha tail\x1b[D\x1b[D\x1b[D\x1b[D\x1b[D', b'@src/alpha.zig  File')
        send(b'\t', '❯ check @src/alpha.zig tail'.encode())
        send(b'\x05\x15/qu\t\r', b'Goodbye!')
        read_until(b'\x1b[?1006l\x1b[?1000l', raw=True)
        assert process.wait(timeout=5) == 0
        assert termios.tcgetattr(slave) == original
        print('PASS: slash-command history, mouse scrolling, command navigation, explicit submission, file search, CJK/spaces, suffix preservation and terminal restoration')
    finally:
        if process.poll() is None:
            process.kill()
            process.wait()
        os.close(master)
        os.close(slave)
