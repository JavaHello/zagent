#!/usr/bin/env python3
"""Compare a native Zig zproxy with the original CLI on extracted C fixtures.

Run inside an isolated namespace. Only `check` and `fw show` are executed;
this script never installs firewall rules or changes policy routing.
"""
import argparse
import ast
import difflib
import hashlib
import json
from pathlib import Path
import re
import subprocess
import tempfile


def fixtures(source):
    text = (source / 'tests/test_main.c').read_text()
    pattern = r'\b(conf_error|load_conf)\(\s*((?:"(?:\\.|[^"\\])*"\s*)+),'
    cases = []
    for match in re.finditer(pattern, text):
        line = text.count('\n', 0, match.start()) + 1
        body = ''.join(ast.literal_eval(part) for part in re.findall(r'"(?:\\.|[^"\\])*"', match.group(2)))
        cases.append({'id': f'config-line-{line}', 'source_line': line,
                      'expected_success': match.group(1) == 'load_conf', 'config': body})
    return cases


def run(binary, config, command):
    result = subprocess.run([str(binary), '-c', str(config), *command],
                            capture_output=True, text=True, timeout=10)
    return {'returncode': result.returncode, 'stdout': result.stdout, 'stderr': result.stderr}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source', type=Path, required=True, help='Original C source tree')
    parser.add_argument('--reference', type=Path, required=True, help='Built original zproxy binary')
    parser.add_argument('--candidate', type=Path, help='Built native Zig zproxy binary')
    parser.add_argument('--output', type=Path, required=True, help='Detailed JSON report')
    args = parser.parse_args()
    source, reference = args.source.resolve(), args.reference.resolve()
    candidate = args.candidate.resolve() if args.candidate else None
    cases = fixtures(source)
    assert cases, 'No original config fixtures found'
    failures, baseline_failures = [], []
    with tempfile.TemporaryDirectory(prefix='zproxy-parity-') as temporary:
        directory = Path(temporary)
        for case in cases:
            config = directory / (case['id'] + '.conf')
            config.write_text(case['config'])
            oracle = run(reference, config, ['check'])
            case['reference_check'] = oracle
            if (oracle['returncode'] == 0) != case['expected_success']:
                baseline_failures.append(case['id'])
            if candidate:
                actual = run(candidate, config, ['check'])
                case['candidate_check'] = actual
                if (actual['returncode'] == 0) != (oracle['returncode'] == 0):
                    failures.append({'id': case['id'], 'command': 'check', 'problem': 'Acceptance differs'})
            if oracle['returncode'] == 0:
                fw_oracle = run(reference, config, ['fw', 'show'])
                case['reference_fw_show'] = fw_oracle
                if candidate:
                    fw_actual = run(candidate, config, ['fw', 'show'])
                    case['candidate_fw_show'] = fw_actual
                    if fw_actual['returncode'] != fw_oracle['returncode'] or fw_actual['stdout'].strip() != fw_oracle['stdout'].strip():
                        difference = ''.join(difflib.unified_diff(
                            fw_oracle['stdout'].splitlines(True), fw_actual['stdout'].splitlines(True),
                            fromfile='reference', tofile='zig'))
                        failures.append({'id': case['id'], 'command': 'fw show', 'problem': 'Firewall preview differs', 'diff': difference})
    report = {'original_test_source_sha256': hashlib.sha256((source / 'tests/test_main.c').read_bytes()).hexdigest(),
              'candidate': str(candidate) if candidate else None, 'case_count': len(cases),
              'baseline_failures': baseline_failures, 'failures': failures, 'cases': cases}
    args.output.write_text(json.dumps(report, ensure_ascii=False, indent=2))
    print(json.dumps({'cases': len(cases), 'baseline_failures': len(baseline_failures),
                      'candidate_failures': len(failures) if candidate else None, 'report': str(args.output)}))
    return 1 if baseline_failures or failures else 0


if __name__ == '__main__':
    raise SystemExit(main())
