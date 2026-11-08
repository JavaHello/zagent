#!/usr/bin/env python3
"""Compare real nftables/policy routes and lifecycle against the C zproxy.

Every profile runs in its own network namespace inside a private user namespace.
The host network and both implementation trees remain untouched.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile

GENERAL = '[general]\ndns_hijack=false\nresolved_flush=false\nstate_file=\n'
DIRECT = '[outbound:direct]\ntype=direct\n'
CATCHALL = '[route]\ntarget=direct\n'
PROFILES = {
    'direct': DIRECT + CATCHALL,
    'tproxy': DIRECT + '[outbound:proxy]\ntype=tproxy\nport=17891\n[route]\ntarget=proxy\ntype=IP-CIDR\n198.18.0.0/15\n[route]\ntarget=proxy\ntype=DOMAIN-SUFFIX\nexample.test\n' + CATCHALL,
    'redirect': DIRECT + '[outbound:proxy]\ntype=redirect\nport=17892\nudp=reject\n[route]\ntarget=proxy\ntype=DST-PORT\n8443\n' + CATCHALL,
    'device': DIRECT + '[outbound:tunnel]\ntype=device\ndev=audit0\nsource=10.99.0.1\n[route]\ntarget=tunnel\ntype=IP-CIDR\n10.77.0.0/16\n' + CATCHALL,
    'relay_inbound': DIRECT + '[outbound:remote]\ntype=socks5\nserver=127.0.0.1\nport=11080\nlisten=17901\nudp=handoff\n[outbound:http]\ntype=http\nserver=127.0.0.1\nport=11081\nlisten=17902\n[inbound:lan]\nlisten=0.0.0.0:18080\ningress=lo,audit0\nusername=alice\npassword=secret\n[route]\ntarget=remote\ntype=DOMAIN-SUFFIX\nexample.test\n' + CATCHALL,
    'dnat': DIRECT + '[dnat:forward]\nport=18090\nto=192.0.2.100:443\nproto=tcp+udp\naddress=10.99.0.1\n' + CATCHALL,
}


def run(command, timeout=15):
    result = subprocess.run(command, capture_output=True, text=True, timeout=timeout)
    return {'command': command, 'returncode': result.returncode, 'stdout': result.stdout, 'stderr': result.stderr}


def checked(command):
    result = run(command)
    if result['returncode'] != 0:
        raise RuntimeError(json.dumps(result))
    return result['stdout']


def normalize(value):
    if isinstance(value, dict):
        return {k: normalize(v) for k, v in value.items() if k not in ('handle', 'packets', 'bytes', 'expires')}
    if isinstance(value, list):
        return [normalize(v) for v in value if not (isinstance(v, dict) and 'metainfo' in v)]
    return value


def routing_state():
    return {f'{family}_{kind}': normalize(json.loads(checked(['ip', '-j', family, kind, 'show', *(['table', 'all'] if kind == 'route' else [])])))
            for family in ('-4', '-6') for kind in ('rule', 'route')}


def kernel_state():
    return dict(routing_state(), nft=normalize(json.loads(checked(['nft', '-j', 'list', 'table', 'inet', 'zproxy']))))


def private_user_namespace():
    mapping = Path('/proc/self/uid_map').read_text().split()
    assert os.geteuid() == 0 and len(mapping) == 3 and mapping[2] == '1', 'Refusing a host-namespace kernel test'


def run_case(name):
    private_user_namespace()
    checked(['ip', 'link', 'set', 'lo', 'up'])
    checked(['ip', 'link', 'add', 'audit0', 'type', 'dummy'])
    checked(['ip', 'addr', 'add', '10.99.0.1/24', 'dev', 'audit0'])
    checked(['ip', 'link', 'set', 'audit0', 'up'])
    # Wait only for the kernel's IPv6 DAD so baseline route state is stable.
    checked(['sysctl', '-qw', 'net.ipv6.conf.audit0.accept_dad=0'])
    baseline = routing_state()
    result = {'profile': name, 'implementations': {}, 'failures': []}
    with tempfile.TemporaryDirectory(prefix='zproxy-kernel-') as temporary:
        config = Path(temporary) / 'config'
        config.write_text(GENERAL + PROFILES[name])
        for label, binary in [('reference', '/reference-original'), ('candidate', '/reference/zproxy')]:
            operations = [run([binary, '-c', str(config), 'check'])]
            operations.append(run([binary, '-c', str(config), 'fw', 'up']))
            states = []
            if all(op['returncode'] == 0 for op in operations):
                states.append(kernel_state())
                for _ in range(2):
                    operations.append(run([binary, '-c', str(config), 'fw', 'up']))
                operations.append(run([binary, '-c', str(config), 'fw', 'refresh']))
                states.append(kernel_state())
                if states[0] != states[1]:
                    result['failures'].append(label + ': repeated up/refresh changed kernel state')
            operations.append(run([binary, '-c', str(config), 'fw', 'down']))
            table_remains = run(['nft', 'list', 'table', 'inet', 'zproxy'])['returncode'] == 0
            after = routing_state()
            if table_remains or after != baseline:
                result['failures'].append(label + ': fw down did not restore initial kernel state')
            if any(op['returncode'] != 0 for op in operations):
                result['failures'].append(label + ': CLI operation failed')
            result['implementations'][label] = {'operations': operations, 'states': states, 'after_down': after}
        ref = result['implementations']['reference']['states']
        native = result['implementations']['candidate']['states']
        if ref != native:
            result['failures'].append('candidate differs from reference kernel state')
    return result


def main():
    if '--case' in sys.argv:
        result = run_case(sys.argv[sys.argv.index('--case') + 1])
        print(json.dumps(result))
        return 0
    if '--inside' in sys.argv:
        private_user_namespace()
        results = []
        for name in PROFILES:
            child = run(['unshare', '-n', 'python3', '/kernel-audit.py', '--case', name], timeout=90)
            if child['returncode'] != 0:
                results.append({'profile': name, 'failures': ['test driver failed'], 'error': child})
            else:
                results.append(json.loads(child['stdout']))
        print(json.dumps({'profiles': results}, indent=2))
        return 1 if any(result['failures'] for result in results) else 0
    from zproxy_e2e import namespace_command
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--reference-root', required=True, type=Path)
    parser.add_argument('--candidate', required=True, type=Path)
    parser.add_argument('--output', required=True, type=Path)
    args = parser.parse_args()
    root = args.reference_root.resolve(strict=True)
    candidate = args.candidate.resolve(strict=True)
    command = namespace_command(root, candidate, 180, ['python3', '/kernel-audit.py', '--inside'])
    index = command.index('--')
    command[index:index] = ['--ro-bind', str(Path(__file__).resolve()), '/kernel-audit.py']
    args.output.parent.mkdir(parents=True, exist_ok=True)
    with args.output.open('w') as output:
        status = subprocess.run(command, env={'PATH': '/usr/bin:/bin'}, stdout=output, stderr=subprocess.STDOUT).returncode
    print(json.dumps({'exit': status, 'candidate_sha256': hashlib.sha256(candidate.read_bytes()).hexdigest(), 'report': str(args.output)}))
    return status


if __name__ == '__main__':
    raise SystemExit(main())
