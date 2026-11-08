#!/usr/bin/env python3
"""Verify DoT connection limits, real pipelining, ID routing and connection reuse.

The TLS upstream waits for eight distinct concurrent DNS queries, then answers
in reverse order. Clients deliberately reuse the same DNS ID on different UDP
sockets. With dns_conns=1 all traffic must use one persistent TLS connection.
"""
import argparse
import concurrent.futures
import hashlib
import json
import os
from pathlib import Path
import signal
import socket
import ssl
import struct
import subprocess
import sys
import tempfile
import threading
import time

BATCH = int(sys.argv[sys.argv.index("--batch") + 1]) if "--batch" in sys.argv else 8
assert 1 <= BATCH <= 128


def query(index):
    name = f'case-{index}.pipeline.test'
    encoded = b''.join(bytes([len(label)]) + label.encode() for label in name.split('.')) + b'\0'
    return name, struct.pack('!HHHHHH', 0x2a2a, 0x0100, 1, 0, 0, 0) + encoded + struct.pack('!HH', 1, 1)


def qname(packet):
    offset, labels = 12, []
    while packet[offset]:
        length = packet[offset]
        labels.append(packet[offset + 1:offset + 1 + length].decode())
        offset += length + 1
    return '.'.join(labels)


def inside(fail_closed=False, prefetch=False, degraded=False):
    if degraded:
        fail_closed = True
    mapping = Path('/proc/self/uid_map').read_text().split()
    assert os.geteuid() == 0 and len(mapping) == 3 and mapping[2] == '1', 'Refusing a host network test'
    subprocess.run(['ip', 'link', 'set', 'lo', 'up'], check=True)
    expected_batch = 1 if (fail_closed or prefetch) else BATCH
    with tempfile.TemporaryDirectory(prefix='zproxy-pipeline-') as temporary:
        work = Path(temporary)
        subprocess.run(['openssl', 'req', '-x509', '-newkey', 'rsa:2048', '-nodes', '-days', '1',
                        '-subj', '/CN=pipeline.test', '-keyout', str(work / 'key'), '-out', str(work / 'cert')],
                       check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        context.load_cert_chain(str(work / 'cert'), str(work / 'key'))
        listener = socket.socket()
        listener.bind(('127.0.0.1', 0))
        listener.listen(32)
        listener.settimeout(0.2)
        upstream_port = listener.getsockname()[1]
        reserved = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        reserved.bind(('127.0.0.1', 0))
        dns_port = reserved.getsockname()[1]
        reserved.close()
        lock, ready, stop = threading.Lock(), threading.Event(), threading.Event()
        state = {'connections': 0, 'queries': 0, 'per_connection': [], 'errors': []}

        def handle(raw):
            connection = None
            try:
                connection = context.wrap_socket(raw, server_side=True)
                connection.settimeout(0.1)
                with lock:
                    slot = len(state['per_connection'])
                    state['per_connection'].append(0)
                    state['connections'] += 1
                buffered, pending = b'', []
                while not stop.is_set():
                    try:
                        data = connection.recv(65535)
                        if not data:
                            break
                        buffered += data
                    except socket.timeout:
                        pass
                    while len(buffered) >= 2 and len(buffered) >= 2 + int.from_bytes(buffered[:2], 'big'):
                        length = int.from_bytes(buffered[:2], 'big')
                        packet, buffered = buffered[2:2 + length], buffered[2 + length:]
                        pending.append(packet)
                        with lock:
                            state['queries'] += 1
                            state['per_connection'][slot] += 1
                            if state['queries'] >= expected_batch:
                                ready.set()
                    if ready.is_set():
                        while pending:
                            packet = pending.pop()  # deliberately out of order on one connection
                            index = int(qname(packet).split('.')[0].split('-')[1])
                            response = packet[:2] + struct.pack('!HHHHH', 0x8180, 1, 1, 0, 0) + packet[12:]
                            response += b'\xc0\x0c' + struct.pack('!HHIH', 1, 1, 4 if prefetch else 60, 4) + bytes([198, 18, 0, index + 1])
                            connection.sendall(len(response).to_bytes(2, 'big') + response)
            except (OSError, ssl.SSLError) as error:
                if not stop.is_set():
                    with lock:
                        state['errors'].append(type(error).__name__)
            finally:
                (connection or raw).close()

        def accept():
            while not stop.is_set():
                try:
                    raw, _ = listener.accept()
                except socket.timeout:
                    continue
                except OSError:
                    return
                threading.Thread(target=handle, args=(raw,), daemon=True).start()

        threading.Thread(target=accept, daemon=True).start()
        config = work / 'config'
        config.write_text(f'''[general]
dns_listen=127.0.0.1:{dns_port}
dns_hijack=false
resolved_flush=false
state_file=
dns_conns=1
dns_pipeline={max(BATCH, 16)}
dns_queue=64
dns_timeout=5000
cache_size=64
cache_prefetch=0
cache_stale=0
[dns:stub]
type=dot
server=127.0.0.1
port={upstream_port}
sni=pipeline.test
insecure=true
timeout=5000
[dns-route]
target=stub
''')
        if prefetch:
            config.write_text(config.read_text().replace('cache_prefetch=0', 'cache_prefetch=1\ncache_prefetch_window=3'))
        if fail_closed:
            with socket.socket() as port_reservation:
                port_reservation.bind(('127.0.0.1', 0))
                inbound_port = port_reservation.getsockname()[1]
            with config.open('a') as output:
                output.write(f'[inbound:audit]\nlisten=127.0.0.1:{inbound_port}\n')
            config.write_text(config.read_text().replace("state_file=\n", f"state_file={work}/state\n"))
            with config.open('a') as output:
                output.write('[outbound:proxy]\ntype=tproxy\nport=17891\n[route]\ntarget=proxy\ntype=DOMAIN-SUFFIX\npipeline.test\n[route]\ntarget=direct\n')
        log = (work / 'daemon.log').open('w')
        daemon = subprocess.Popen(['/reference/zproxy', '-c', str(config), 'run' if fail_closed else 'dns'], stdout=log, stderr=subprocess.STDOUT)
        answers, failures, shutdown = [], [], None
        try:
            deadline = time.monotonic() + 5
            while time.monotonic() < deadline:
                if daemon.poll() is not None:
                    raise RuntimeError('DNS daemon exited during startup')
                with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as probe:
                    try:
                        probe.bind(('127.0.0.1', dns_port))
                    except OSError:
                        break
                time.sleep(0.01)
            else:
                raise RuntimeError('DNS listener never bound')

            def ask(index, expected_rcode=None):
                name, packet = query(index)
                with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as client:
                    client.settimeout(7)
                    client.sendto(packet, ('127.0.0.1', dns_port))
                    result, _ = client.recvfrom(65535)
                if expected_rcode is not None:
                    return result[:2] == packet[:2] and (result[3] & 15) == expected_rcode
                if fail_closed:
                    return result[:2] == packet[:2] and (result[3] & 15) == 2
                return result[:2] == packet[:2] and qname(result) == name and result[-4:] == bytes([198, 18, 0, index + 1])

            if degraded:
                answers.extend(ask(index, 2) for index in range(3))
                subprocess.run(['/reference/zproxy', '-c', str(config), 'fw', 'up'], check=True,
                               stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
                answers.append(ask(3, 2))
                daemon.send_signal(signal.SIGHUP)
                deadline = time.monotonic() + 4
                while time.monotonic() < deadline:
                    if 'config reloaded' in (work / 'daemon.log').read_text():
                        break
                    time.sleep(0.01)
                else:
                    failures.append('degraded recovery reload did not finish')
                answers.append(ask(4, 0))
                if not all(answers):
                    failures.append('initial failed writes did not stay fail-closed until reload recovery')
                if (work / 'daemon.log').read_text().count('giving up on installing resolved addresses') != 1:
                    failures.append('degraded write failure was not reported once')
            elif prefetch:
                answers.extend(ask(0) for _ in range(3))
                if state['queries'] != 1:
                    failures.append('hot cache setup did not reuse the initial answer')
                deadline = time.monotonic() + 3.8
                while time.monotonic() < deadline and state['queries'] < 2:
                    time.sleep(0.02)
                if state['queries'] < 2:
                    failures.append('hot cache entry was not refreshed upstream before expiry')
                if not all(answers):
                    failures.append('prefetch setup queries failed')
            elif fail_closed:
                # The second answer may hit a cache/shadow entry; failure to
                # install the first address must not make later requests bypass.
                answers.extend(ask(0) for _ in range(2))
                if not all(answers):
                    failures.append('DNS returned a successful proxy-routed answer without its firewall set installed')
            else:
                with concurrent.futures.ThreadPoolExecutor(max_workers=BATCH) as pool:
                    answers.extend(pool.map(ask, range(BATCH)))
                for index in range(BATCH, BATCH + 3):
                    answers.append(ask(index))
                if not all(answers) or len(answers) != BATCH + 3:
                    failures.append('DNS responses/IDs/questions did not match each client')
                if state['connections'] != 1:
                    failures.append('dns_conns=1 did not bound and reuse one TLS connection')
                if max(state['per_connection'], default=0) < BATCH:
                    failures.append('concurrent DNS requests were not pipelined on one TLS connection')
        except Exception as error:
            failures.append(repr(error))
        finally:
            daemon.send_signal(signal.SIGTERM) if daemon.poll() is None else None
            try:
                shutdown = daemon.wait(timeout=8)
            except subprocess.TimeoutExpired:
                failures.append('DNS daemon did not shut down promptly')
                daemon.kill()
                shutdown = daemon.wait()
            stop.set()
            listener.close()
            log.close()
        if shutdown != 0:
            failures.append('DNS daemon shutdown was not successful')
        report = {'batch': BATCH, 'configured_pipeline': max(BATCH, 16), 'answers_correct': sum(answers), 'answers_expected': 5 if degraded else 3 if prefetch else 2 if fail_closed else BATCH + 3, 'upstream': state,
                  'shutdown': shutdown, 'failures': failures, 'daemon_log': (work / 'daemon.log').read_text()[-5000:]}
        print(json.dumps(report, indent=2))
        return 1 if failures else 0


def main():
    if '--inside' in sys.argv:
        return inside('--fail-closed' in sys.argv, '--prefetch' in sys.argv, '--degraded' in sys.argv)
    from zproxy_e2e import namespace_command
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--batch', type=int, default=8)
    parser.add_argument('--fail-closed', action='store_true')
    parser.add_argument('--prefetch', action='store_true')
    parser.add_argument('--degraded', action='store_true')
    parser.add_argument('--reference-root', type=Path, required=True)
    parser.add_argument('--candidate', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    root, candidate = args.reference_root.resolve(strict=True), args.candidate.resolve(strict=True)
    command = namespace_command(root, candidate, 90, ['python3', '/dns-pipeline.py', '--inside', '--batch', str(args.batch), *(['--fail-closed'] if args.fail_closed else []), *(['--prefetch'] if args.prefetch else []), *(['--degraded'] if args.degraded else [])])
    index = command.index('--')
    command[index:index] = ['--ro-bind', str(Path(__file__).resolve()), '/dns-pipeline.py']
    args.output.parent.mkdir(parents=True, exist_ok=True)
    with args.output.open('w') as output:
        status = subprocess.run(command, env={'PATH': '/usr/bin:/bin'}, stdout=output, stderr=subprocess.STDOUT).returncode
    print(json.dumps({'exit': status, 'candidate_sha256': hashlib.sha256(candidate.read_bytes()).hexdigest(), 'report': str(args.output)}))
    return status


if __name__ == '__main__':
    raise SystemExit(main())
