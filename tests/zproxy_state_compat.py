#!/usr/bin/env python3
"""A persisted original-format address must survive a native Zig upgrade."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time


def run(command):
    result = subprocess.run(command, capture_output=True, text=True, timeout=15)
    return {'returncode': result.returncode, 'stdout': result.stdout, 'stderr': result.stderr}


def inside():
    mapping = Path('/proc/self/uid_map').read_text().split()
    assert os.geteuid() == 0 and len(mapping) == 3 and mapping[2] == '1', 'Refusing a host network test'
    subprocess.run(['ip', 'link', 'set', 'lo', 'up'], check=True)
    identity = 14695981039346656037
    for byte in b'proxy\xff\x03':
        identity = ((identity ^ byte) * 1099511628211) & ((1 << 64) - 1)
    report = {'implementations': {}, 'failures': []}
    with tempfile.TemporaryDirectory(prefix='zproxy-state-') as temporary:
        work = Path(temporary)
        state = work / 'state'
        config = work / 'config'
        config.write_text(f'''[general]
dns_hijack=false
resolved_flush=false
state_file={state}
[outbound:proxy]
type=tproxy
port=17891
[route]
target=proxy
type=DOMAIN-SUFFIX
example.test
[route]
target=direct
''')
        for label, binary in [('reference', '/reference-original'), ('candidate', '/reference/zproxy')]:
            expiry = int(time.time() * 1000) + 300000
            state.write_text(f'# zproxy state 1\n4 198.18.0.9 zp_proxy_w4 {identity:016x} zp_proxy_w4 {identity:016x} {expiry}\n')
            up = run([binary, '-c', str(config), 'fw', 'up'])
            element = run(['nft', 'get', 'element', 'inet', 'zproxy', 'zp_proxy_w4', '{', '198.18.0.9', '}'])
            down = run([binary, '-c', str(config), 'fw', 'down'])
            report['implementations'][label] = {'up': up, 'element': element, 'down': down}
            if up['returncode'] or element['returncode'] or down['returncode']:
                report['failures'].append(label + ': original state entry was not restored')
    print(json.dumps(report, indent=2))
    return 1 if report['failures'] else 0


def main():
    if '--inside' in sys.argv:
        return inside()
    from zproxy_e2e import namespace_command
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--reference-root', type=Path, required=True)
    parser.add_argument('--candidate', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    root, candidate = args.reference_root.resolve(strict=True), args.candidate.resolve(strict=True)
    command = namespace_command(root, candidate, 90, ['python3', '/state-compat.py', '--inside'])
    index = command.index('--')
    command[index:index] = ['--ro-bind', str(Path(__file__).resolve()), '/state-compat.py']
    args.output.parent.mkdir(parents=True, exist_ok=True)
    with args.output.open('w') as output:
        status = subprocess.run(command, env={'PATH': '/usr/bin:/bin'}, stdout=output, stderr=subprocess.STDOUT).returncode
    print(json.dumps({'exit': status, 'candidate_sha256': hashlib.sha256(candidate.read_bytes()).hexdigest(), 'report': str(args.output)}))
    return status


if __name__ == '__main__':
    raise SystemExit(main())
