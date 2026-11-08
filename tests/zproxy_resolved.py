#!/usr/bin/env python3
"""Exercise the resolved varlink client with a namespace-local fake service."""
import argparse
import json
import os
from pathlib import Path
import socket
import subprocess
import sys
import tempfile
import threading
import time


def inside():
    mapping = Path('/proc/self/uid_map').read_text().split()
    assert os.geteuid() == 0 and len(mapping) == 3 and mapping[2] == '1'
    subprocess.run(['ip', 'link', 'set', 'lo', 'up'], check=True)
    path = Path('/run/systemd/resolve/io.systemd.Resolve.Monitor')
    path.parent.mkdir(parents=True)
    results = []
    cases = [('ok', b'{"parameters":{}}\0', False),
             ('service-error', b'{"error":"org.varlink.service.PermissionDenied","parameters":{}}\0', True),
             ('application-error', b'{"error":"io.systemd.Resolve.NotSupported","parameters":{}}\0', True),
             ('malformed', b'[]\0', True), ('oversized', b' ' * 4200, True), ('eof', b'', True)]
    with tempfile.TemporaryDirectory(prefix='zproxy-resolved-') as temporary:
        work = Path(temporary)
        config = work / 'config'
        config.write_text('''[general]
dns_listen=127.0.0.1:5353
resolved_flush=true
state_file=
[inbound:audit]
listen=127.0.0.1:1080
[dns:unused]
type=dot
server=127.0.0.1
port=8853
sni=x.test
insecure=true
[route]
target=direct
''')
        subprocess.run(['/reference/zproxy', '-c', str(config), 'fw', 'up'], check=True,
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        for name, reply, expected_warning in cases:
            listener = socket.socket(socket.AF_UNIX)
            listener.bind(str(path))
            listener.listen(1)
            listener.settimeout(5)
            requests, errors = [], []

            def serve():
                try:
                    connection, _ = listener.accept()
                    with connection:
                        connection.settimeout(3)
                        request = b''
                        while b'\0' not in request:
                            part = connection.recv(4096)
                            if not part:
                                raise EOFError('unterminated request')
                            request += part
                        requests.append(json.loads(request.split(b'\0')[0]))
                        if reply:
                            connection.sendall(reply[:5])
                            time.sleep(0.01)
                            if reply[5:]:
                                connection.sendall(reply[5:])
                except Exception as error:
                    errors.append(repr(error))
            thread = threading.Thread(target=serve, daemon=True)
            thread.start()
            log = (work / 'daemon.log').open('w')
            daemon = subprocess.Popen(['/reference/zproxy', '-c', str(config), 'run'], stdout=log, stderr=subprocess.STDOUT)
            try:
                for _ in range(200):
                    if requests and not thread.is_alive():
                        time.sleep(0.05)
                        break
                    if daemon.poll() is not None:
                        break
                    time.sleep(0.02)
                daemon.terminate()
                daemon.wait(timeout=5)
            finally:
                if daemon.poll() is None:
                    daemon.kill()
                    daemon.wait()
                thread.join(timeout=1)
                listener.close()
                path.unlink()
                log.close()
            output = (work / 'daemon.log').read_text()
            warning = 'could not flush' in output
            request_ok = requests == [{'method': 'io.systemd.Resolve.Monitor.FlushCaches', 'parameters': {}}]
            results.append({'case': name, 'request_ok': request_ok, 'warning': warning,
                            'expected_warning': expected_warning, 'shutdown': daemon.returncode, 'errors': errors,
                            'complete': request_ok and warning == expected_warning and not errors and daemon.returncode == 0,
                            'log': output[-1500:]})
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
    command = namespace_command(args.reference_root.resolve(strict=True), args.candidate.resolve(strict=True), 45,
                                ['python3', '/resolved.py', '--inside'])
    index = command.index('--')
    command[index:index] = ['--ro-bind', str(Path(__file__).resolve()), '/resolved.py']
    with args.output.open('w') as output:
        result = subprocess.run(command, env={'PATH': '/usr/bin:/bin'}, stdout=output, stderr=subprocess.STDOUT)
    print(json.dumps({'exit': result.returncode, 'report': str(args.output)}))
    return result.returncode


if __name__ == '__main__':
    raise SystemExit(main())
