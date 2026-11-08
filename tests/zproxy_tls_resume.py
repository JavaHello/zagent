#!/usr/bin/env python3
"""Force DoT reconnects and observe actual server-side TLS session reuse."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import socket
import ssl
import struct
import subprocess
import sys
import tempfile
import threading
import time


def exact(connection, count):
    result = b''
    while len(result) < count:
        part = connection.recv(count - len(result))
        if not part:
            raise EOFError('short TLS frame')
        result += part
    return result


def inside():
    mapping = Path('/proc/self/uid_map').read_text().split()
    assert os.geteuid() == 0 and len(mapping) == 3 and mapping[2] == '1'
    subprocess.run(['ip', 'link', 'set', 'lo', 'up'], check=True)
    results = []
    with tempfile.TemporaryDirectory(prefix='zproxy-resume-') as temporary:
        work = Path(temporary)
        subprocess.run(['openssl', 'req', '-x509', '-newkey', 'rsa:2048', '-nodes', '-days', '1',
                        '-subj', '/CN=resume.test', '-keyout', str(work / 'key'), '-out', str(work / 'cert')],
                       check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        for version in (ssl.TLSVersion.TLSv1_3, ssl.TLSVersion.TLSv1_2):
            context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
            context.minimum_version = context.maximum_version = version
            context.load_cert_chain(str(work / 'cert'), str(work / 'key'))
            listener = socket.socket()
            listener.bind(('127.0.0.1', 0))
            listener.listen(8)
            listener.settimeout(8)
            reused, errors = [], []

            def serve():
                try:
                    for _ in range(3):
                        raw, _ = listener.accept()
                        with context.wrap_socket(raw, server_side=True) as connection:
                            connection.settimeout(3)
                            reused.append(connection.session_reused)
                            packet = exact(connection, int.from_bytes(exact(connection, 2), 'big'))
                            reply = packet[:2] + struct.pack('!HHHHH', 0x8180, 1, 1, 0, 0) + packet[12:]
                            reply += b'\xc0\x0c' + struct.pack('!HHIH', 1, 1, 60, 4) + bytes([198, 18, 0, 42])
                            connection.sendall(len(reply).to_bytes(2, 'big') + reply)
                            # Send close_notify and let the client process tickets and EOF.
                            try:
                                connection.unwrap().close()
                            except (OSError, ssl.SSLError):
                                pass
                except Exception as error:
                    errors.append(repr(error))

            thread = threading.Thread(target=serve, daemon=True)
            thread.start()
            with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as reserve:
                reserve.bind(('127.0.0.1', 0))
                dns_port = reserve.getsockname()[1]
            config = work / 'config'
            config.write_text(f'''[general]
dns_listen=127.0.0.1:{dns_port}
dns_hijack=false
resolved_flush=false
state_file=
dns_conns=1
dns_pipeline=16
dns_timeout=3000
cache_prefetch=0
[dns:stub]
type=dot
server=127.0.0.1
port={listener.getsockname()[1]}
sni=resume.test
insecure=true
[dns-route]
target=stub
''')
            log = (work / 'daemon.log').open('w')
            daemon = subprocess.Popen(['/reference/zproxy', '-c', str(config), 'dns'], stdout=log, stderr=subprocess.STDOUT)
            answers = []
            try:
                time.sleep(0.25)
                for index in range(3):
                    labels = f'query-{index}.resume.test'.split('.')
                    name = b''.join(bytes([len(label)]) + label.encode() for label in labels) + b'\0'
                    packet = struct.pack('!HHHHHH', index + 1, 0x0100, 1, 0, 0, 0) + name + struct.pack('!HH', 1, 1)
                    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as client:
                        client.settimeout(5)
                        client.sendto(packet, ('127.0.0.1', dns_port))
                        reply, _ = client.recvfrom(65535)
                    answers.append(reply[:2] == packet[:2] and reply[-4:] == bytes([198, 18, 0, 42]))
                    time.sleep(0.3)
            except Exception as error:
                errors.append(repr(error))
            finally:
                daemon.terminate()
                try:
                    daemon.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    daemon.kill()
                    daemon.wait()
                listener.close()
                thread.join(timeout=1)
                log.close()
            results.append({'version': version.name, 'reused': reused, 'answers': answers,
                            'errors': errors, 'shutdown': daemon.returncode,
                            'complete': reused == [False, True, True] and answers == [True] * 3 and not errors and daemon.returncode == 0,
                            'log': (work / 'daemon.log').read_text()[-2500:]})
    print(json.dumps(results, indent=2))
    return 0 if all(result['complete'] for result in results) else 1


def main():
    if '--inside' in sys.argv:
        return inside()
    from zproxy_e2e import namespace_command
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--reference-root', type=Path, required=True)
    parser.add_argument('--candidate', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    candidate = args.candidate.resolve(strict=True)
    command = namespace_command(args.reference_root.resolve(strict=True), candidate, 40,
                                ['python3', '/tls-resume.py', '--inside'])
    index = command.index('--')
    command[index:index] = ['--ro-bind', str(Path(__file__).resolve()), '/tls-resume.py']
    args.output.parent.mkdir(parents=True, exist_ok=True)
    with args.output.open('w') as output:
        status = subprocess.run(command, env={'PATH': '/usr/bin:/bin'}, stdout=output, stderr=subprocess.STDOUT).returncode
    print(json.dumps({'exit': status, 'candidate_sha256': hashlib.sha256(candidate.read_bytes()).hexdigest(), 'report': str(args.output)}))
    return status


if __name__ == '__main__':
    raise SystemExit(main())
