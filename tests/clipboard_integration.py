#!/usr/bin/env python3
"""Real tmux copy with default clipboard policy and passthrough disabled."""
import base64
import fcntl
import os
from pathlib import Path
import pty
import select
import shutil
import struct
import subprocess
import tempfile
import termios
import time
from mock_api import trust_workspace


def main():
    tmux = shutil.which('tmux')
    if not tmux:
        print('clipboard integration: skipped (tmux not installed)')
        return
    binary = Path(__file__).resolve().parents[1] / 'zig-out/bin/zagent'
    with tempfile.TemporaryDirectory(prefix='zagent-clipboard-') as directory:
        env = dict(os.environ, HOME=directory, XDG_CONFIG_HOME=directory,
                   TERM='xterm-256color', AI_PROVIDER='openai', AI_KEY='test',
                   AI_MODEL='clipboard-test', AI_MEMORY='0')
        env.pop('TMUX', None)
        env.pop('TMUX_PANE', None)
        trust_workspace(directory, env)
        # A private server: never alter the user's tmux options or buffers.
        socket = f'zagent-clipboard-{os.getpid()}'
        command = [tmux, '-L', socket]

        def control(*args, check=True):
            return subprocess.run(command + list(args), env=env, check=check,
                                  stdout=subprocess.PIPE, stderr=subprocess.PIPE)

        master, slave = pty.openpty()
        fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack('HHHH', 30, 100, 0, 0))
        process = subprocess.Popen(command + ['-f', '/dev/null', 'new-session',
                                   '-s', 'copy', '-c', directory, str(binary)],
                                   env=env, stdin=slave, stdout=slave, stderr=slave)
        output = bytearray()

        def drain():
            if select.select([master], [], [], .05)[0]:
                output.extend(os.read(master, 65536))

        try:
            deadline = time.monotonic() + 12
            while True:
                drain()
                pane = control('capture-pane', '-p', '-t', 'copy', check=False)
                lines = pane.stdout.decode().splitlines()
                if any('Model  clipboard-test' in line for line in lines) and '❯'.encode() in output:
                    break
                assert process.poll() is None, output.decode(errors='replace')
                assert time.monotonic() < deadline, output.decode(errors='replace')
            control('set-option', '-s', 'set-clipboard', 'external')
            control('set-option', '-g', 'allow-passthrough', 'off')
            # This PTY emulates an OSC 52-capable terminal; make that explicit
            # rather than depending on the host's terminfo database.
            control('set-option', '-as', 'terminal-features', ',xterm*:clipboard')
            control('set-option', '-as', 'terminal-overrides', r',*:Ms=\E]52;%p1%s;%p2%s\007')
            row, line = next((i + 1, s) for i, s in enumerate(lines) if 'Model  clipboard-test' in s)
            col = line.index('Model') + 1
            # Inject reports into the application, bypassing tmux mouse bindings.
            mouse = f'\x1b[<0;{col};{row}M\x1b[<32;{col+4};{row}M\x1b[<0;{col+4};{row}m'
            control('send-keys', '-t', 'copy', '-l', mouse)
            # tmux uses an empty selection parameter (the terminal default).
            expected = b'\x1b]52;;' + base64.b64encode(b'Model') + b'\x07'
            deadline = time.monotonic() + 8
            while expected not in output:
                drain()
                assert time.monotonic() < deadline, (
                    control('save-buffer', '-', check=False).stdout,
                    [s for s in control('info').stdout.decode().splitlines() if 'Ms:' in s],
                    repr(bytes(output[-250:])))
            assert control('save-buffer', '-').stdout == b'Model'
            print('clipboard integration: tmux buffer and terminal OSC 52 verified')
        finally:
            control('kill-server', check=False)
            try:
                process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait()
            os.close(master)
            os.close(slave)


if __name__ == '__main__':
    main()
