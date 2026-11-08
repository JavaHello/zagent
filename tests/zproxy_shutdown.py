#!/usr/bin/env python3
"""Repeat shutdown with pending SOCKS handshakes, TCP relays and UDP controls."""
import argparse
import json
import os
from pathlib import Path
import socket
import signal
import struct
import subprocess
import sys
import tempfile
import threading
import time


def exact(sock, size):
    data = b''
    while len(data) < size:
        part = sock.recv(size - len(data))
        if not part:
            raise EOFError('short SOCKS reply')
        data += part
    return data


def inside():
    mapping = Path('/proc/self/uid_map').read_text().split()
    assert os.geteuid() == 0 and len(mapping) == 3 and mapping[2] == '1'
    subprocess.run(['ip', 'link', 'set', 'lo', 'up'], check=True)
    listener = socket.socket()
    listener.bind(('127.0.0.1', 0))
    listener.listen(32)

    def echo():
        def client(connection):
            with connection:
                try:
                    while data := connection.recv(4096):
                        connection.sendall(data)
                except OSError:
                    pass
        while True:
            connection, _ = listener.accept()
            threading.Thread(target=client, args=(connection,), daemon=True).start()
    threading.Thread(target=echo, daemon=True).start()
    udp_echo = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    udp_echo.bind(('127.0.0.1', 0))
    def echo_udp():
        while True:
            data, peer = udp_echo.recvfrom(65535)
            udp_echo.sendto(data, peer)
    threading.Thread(target=echo_udp, daemon=True).start()
    results = []
    with tempfile.TemporaryDirectory(prefix='zproxy-shutdown-') as temporary:
        work = Path(temporary)
        for index in range(10):
            with socket.socket() as reserve:
                reserve.bind(('127.0.0.1', 0))
                inbound_port = reserve.getsockname()[1]
            config = work / 'config'
            config.write_text(f'''[general]
dns_listen=127.0.0.1:5353
resolved_flush=false
state_file=
[inbound:local]
listen=127.0.0.1:{inbound_port}
[dns:unused]
type=dot
server=127.0.0.1
port=8853
sni=x.test
insecure=true
[route]
target=direct
''')
            log = (work / 'daemon.log').open('w')
            daemon = subprocess.Popen(['/reference/zproxy', '-c', str(config), 'run'], stdout=log, stderr=subprocess.STDOUT)
            clients = []
            try:
                for attempt in range(100):
                    try:
                        pending = socket.create_connection(('127.0.0.1', inbound_port), timeout=1)
                        break
                    except OSError:
                        if daemon.poll() is not None or attempt == 99:
                            raise
                        time.sleep(0.02)
                clients.append(pending)
                for command in (1, 3):
                    client = socket.create_connection(('127.0.0.1', inbound_port), timeout=2)
                    clients.append(client)
                    client.sendall(b'\x05\x01\x00')
                    assert exact(client, 2) == b'\x05\x00'
                    destination = socket.inet_aton('127.0.0.1') if command == 1 else b'\0' * 4
                    port = listener.getsockname()[1] if command == 1 else 0
                    client.sendall(bytes([5, command, 0, 1]) + destination + struct.pack('!H', port))
                    header = exact(client, 4)
                    assert header[:2] == b'\x05\x00', header
                    bound = exact(client, (4 if header[3] == 1 else 16) + 2)
                    if command == 3:
                        udp_relay = (socket.inet_ntoa(bound[:4]), int.from_bytes(bound[4:6], 'big'))
                    if command == 1:
                        client.sendall(b'ACTIVE_RELAY')
                        assert exact(client, 12) == b'ACTIVE_RELAY'
                if index == 0:
                    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as datagrams:
                        frame = b'\0\0\0\x01' + socket.inet_aton('127.0.0.1') + struct.pack('!H', udp_echo.getsockname()[1]) + b'LIVE_UDP'
                        datagrams.settimeout(2)
                        datagrams.sendto(frame, udp_relay)
                        assert datagrams.recvfrom(65535)[0][10:] == b'LIVE_UDP'
                        with socket.socket() as reserve:
                            reserve.bind(('127.0.0.1', 0))
                            changed_port = reserve.getsockname()[1]
                        text = config.read_text().replace(
                            f'[inbound:local]\nlisten=127.0.0.1:{inbound_port}',
                            f'[inbound:changed]\nlisten=127.0.0.1:{changed_port}\nusername=reloaded\npassword=secret')
                        config.write_text(text.replace('target=direct', 'target=reject'))
                        daemon.send_signal(signal.SIGHUP)
                        for attempt in range(100):
                            if 'config reloaded' in (work / 'daemon.log').read_text():
                                break
                            time.sleep(0.02)
                        else:
                            raise AssertionError('reload did not complete: ' + (work / 'daemon.log').read_text())
                        # Restart-only authentication/listener settings stay at
                        # their original values, even if sections are renamed.
                        with socket.create_connection(('127.0.0.1', inbound_port), timeout=2) as check:
                            check.sendall(b'\x05\x01\x00')
                            assert exact(check, 2) == b'\x05\x00'
                        # An already-open UDP association uses the new rules.
                        datagrams.settimeout(0.2)
                        datagrams.sendto(frame, udp_relay)
                        try:
                            datagrams.recvfrom(65535)
                            raise AssertionError('existing UDP association ignored reloaded reject rule')
                        except socket.timeout:
                            pass
                start = time.monotonic()
                daemon.terminate()
                daemon.wait(timeout=3)
                elapsed = time.monotonic() - start
                closed = []
                for client in clients:
                    client.settimeout(1)
                    try:
                        closed.append(client.recv(1) == b'')
                    except ConnectionResetError:
                        closed.append(True)
                results.append({'iteration': index, 'shutdown': daemon.returncode, 'seconds': round(elapsed, 3), 'closed': closed})
                assert daemon.returncode == 0 and closed == [True] * 3, results[-1]
            finally:
                if daemon.poll() is None:
                    daemon.kill()
                    daemon.wait()
                for client in clients:
                    client.close()
                log.close()
    print(json.dumps({'complete': True, 'runs': results}, indent=2))
    return 0


def main():
    if '--inside' in sys.argv:
        return inside()
    from zproxy_e2e import namespace_command
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--reference-root', type=Path, required=True)
    parser.add_argument('--candidate', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    command = namespace_command(args.reference_root.resolve(strict=True), args.candidate.resolve(strict=True), 60,
                                ['python3', '/shutdown.py', '--inside'])
    index = command.index('--')
    command[index:index] = ['--ro-bind', str(Path(__file__).resolve()), '/shutdown.py']
    with args.output.open('w') as output:
        result = subprocess.run(command, env={'PATH': '/usr/bin:/bin'}, stdout=output, stderr=subprocess.STDOUT)
    print(json.dumps({'exit': result.returncode, 'report': str(args.output)}))
    return result.returncode


if __name__ == '__main__':
    raise SystemExit(main())
