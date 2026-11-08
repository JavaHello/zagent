#!/usr/bin/env python3
"""Run zproxy's actual Linux network tests in isolated user/network namespaces.

The reference root must contain the original tests and compiled probe binaries.
A candidate is mounted over /reference/zproxy without modifying either tree.
All virtual interfaces, routes and nftables rules live in the private namespace.
"""
import argparse
import os
from pathlib import Path
import subprocess
import tempfile


def namespace_command(root, candidate, timeout, inner):
    command = [
        '/usr/bin/timeout', '--signal=TERM', '--kill-after=5', str(timeout),
        '/usr/bin/bwrap', '--unshare-all', '--die-with-parent', '--new-session',
        '--uid', '0', '--gid', '0', '--cap-add', 'CAP_NET_ADMIN',
        '--cap-add', 'CAP_NET_RAW', '--cap-add', 'CAP_SYS_ADMIN',
        '--ro-bind', '/usr', '/usr', '--symlink', 'usr/bin', '/bin',
        '--symlink', 'usr/sbin', '/sbin', '--symlink', 'usr/lib', '/lib',
        '--symlink', 'usr/lib64', '/lib64', '--proc', '/proc', '--dev', '/dev',
        '--tmpfs', '/tmp', '--tmpfs', '/run', '--dir', '/var', '--symlink', '/run', '/var/run',
        '--dir', '/etc',
    ]
    for path in ('/etc/passwd', '/etc/group', '/etc/nsswitch.conf', '/etc/ssl/openssl.cnf', '/etc/ssl/certs'):
        command += ['--ro-bind-try', path, path]
    if not Path('/etc/ssl/openssl.cnf').exists():
        command += ['--setenv', 'OPENSSL_CONF', '/dev/null']
    command += [
        '--ro-bind', str(root), '/reference', '--ro-bind', str(root / 'zproxy'), '/reference-original',
        '--ro-bind', str(candidate), '/reference/zproxy',
        '--chdir', '/reference', '--clearenv', '--setenv', 'PATH', '/usr/bin:/bin',
        '--setenv', 'ZP_E2E_IN_NS', '1', '--', *inner,
    ]
    return command


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--reference-root', required=True, type=Path)
    parser.add_argument('--candidate', type=Path)
    parser.add_argument('--output', required=True, type=Path)
    parser.add_argument('--artifacts', type=Path, help='Preserve scenario logs and generated configs')
    parser.add_argument('--long-lived', action='store_true')
    parser.add_argument('--timeout', type=int, default=1200)
    args = parser.parse_args()
    root = args.reference_root.resolve(strict=True)
    candidate = args.candidate.resolve(strict=True) if args.candidate else root / 'zproxy'
    assert os.access(candidate, os.X_OK), f'Candidate is not executable: {candidate}'
    assert 1 <= args.timeout <= 3600, 'timeout must be 1..3600 seconds'
    script = 'longlived_e2e.sh' if args.long_lived else 'tproxy_e2e.sh'
    assert (root / 'tests' / script).is_file(), f'Missing reference test: {script}'
    if not args.long_lived:
        for name in ('test_servers', 'capture_probe', 'udp_probe', 'route_probe', 'dns_probe'):
            assert os.access(root / name, os.X_OK), f'Build the reference test helper: {name}'
    command = namespace_command(root, candidate, args.timeout, ['/usr/bin/bash', '/reference/tests/' + script])
    args.output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='zproxy-e2e-wrapper-') as temporary:
        if args.artifacts:
            args.artifacts.mkdir(parents=True, exist_ok=True)
            # Preserve diagnostics before the original cleanup removes WORK.
            # The test bodies and assertions remain unchanged.
            text = (root / 'tests' / script).read_text()
            assert 'rm -rf "$WORK"' in text, 'Unknown reference cleanup structure'
            text = text.replace('rm -rf "$WORK"', 'cp -a "$WORK/." "$ZP_E2E_ARTIFACTS/"; rm -rf "$WORK"')
            wrapper = Path(temporary) / script
            wrapper.write_text(text)
            index = command.index('--')
            command[index:index] = ['--bind', str(args.artifacts.resolve()), '/audit-artifacts',
                                    '--setenv', 'ZP_E2E_ARTIFACTS', '/audit-artifacts',
                                    '--ro-bind', str(wrapper), '/reference/tests/' + script]
        with args.output.open('w') as log:
            status = subprocess.run(command, env={'PATH': '/usr/bin:/bin'}, stdout=log, stderr=subprocess.STDOUT).returncode
    print(f'{script}: exit={status}; log={args.output}')
    return status


if __name__ == '__main__':
    raise SystemExit(main())
