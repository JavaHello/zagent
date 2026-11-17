#!/usr/bin/env python3
"""Agent Skills: the catalog in the prompt, activation, bundled files and the
refusals that keep a skill inside its own directory."""
import http.server
import json
from pathlib import Path
import subprocess
import tempfile
import threading

from mock_api import send_response, trust_workspace

BINARY = Path(__file__).resolve().parents[1] / 'zig-out/bin/zagent'
DESCRIPTION = 'Use when a demo task needs the installed demo procedure.'
BODY_TAIL = 'LAST-BODY-LINE-2f7c'
# Larger than the tool-output cache threshold: instructions must not be
# replaced by a preview of their beginning.
LONG_BODY = '# Demo\n\n' + ('Follow these steps carefully.\n' * 400) + BODY_TAIL
REFERENCE = 'REFERENCE-NOTES-9a1'
SCRIPT = '#!/bin/sh\necho SCRIPT-RAN-4c3d\n'
SECRET = 'SECRET-OUTSIDE-THE-SKILL'


def prompt_of(request):
    system = request.get('instructions', '')
    for item in request['input']:
        if item.get('role') not in ('system', 'developer'):
            continue
        content = item.get('content', '')
        if isinstance(content, str):
            system += content
            continue
        for part in content:
            if part.get('type') in ('input_text', 'output_text'):
                system += part.get('text', '')
    return system


def tool_names(request):
    return {tool.get('name') for tool in request.get('tools', [])}


def user_text(request):
    text = ''
    for item in request['input']:
        if item.get('role') != 'user':
            continue
        content = item.get('content', '')
        if isinstance(content, str):
            text += content
            continue
        for part in content:
            if part.get('type') in ('input_text', 'output_text'):
                text += part.get('text', '')
    return text


def results_of(request):
    return [item['output'] for item in request['input']
            if item.get('type') == 'function_call_output']


def run(calls, setup, query='Use the installed demo skill'):
    requests = []

    class API(http.server.BaseHTTPRequestHandler):
        def log_message(self, *_):
            pass

        def do_POST(self):
            body = json.loads(self.rfile.read(int(self.headers['Content-Length'])))
            requests.append(body)
            results = [item for item in body['input']
                       if item.get('type') == 'function_call_output']
            index = len(results)
            if index < len(calls):
                name, arguments = calls[index]
                output = [{'type': 'function_call', 'call_id': f'skill-{index}',
                           'name': name, 'arguments': json.dumps(arguments)}]
            else:
                output = [{'type': 'message', 'role': 'assistant', 'content': [
                    {'type': 'output_text', 'text': 'Done'}]}]
            send_response(self, body, {'status': 'completed', 'output': output})

    server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), API)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    try:
        with tempfile.TemporaryDirectory(prefix='zagent-skill-') as directory:
            workspace = Path(directory) / 'project'
            workspace.mkdir()
            env = {'PATH': '/usr/bin:/bin', 'HOME': directory, 'XDG_CONFIG_HOME': directory,
                   'AI_URL': f'http://127.0.0.1:{server.server_port}/v1',
                   'AI_MODEL': 'mock', 'AI_KEY': 'test'}
            state = trust_workspace(workspace, env)
            setup(workspace, state)
            result = subprocess.run([str(BINARY), query],
                                    cwd=workspace, env=env, text=True,
                                    capture_output=True, timeout=120)
            assert result.returncode == 0, result.stderr
    finally:
        server.shutdown()
        server.server_close()
    return requests


def install_skill(workspace, state):
    skill = workspace / '.zagent/skills/demo-skill'
    (skill / 'references').mkdir(parents=True)
    (skill / 'scripts').mkdir()
    (skill / 'SKILL.md').write_text(
        f'---\nname: demo-skill\ndescription: {DESCRIPTION}\n'
        f'license: MIT\nmetadata:\n  author: tests\n---\n\n{LONG_BODY}\n')
    (skill / 'references/notes.md').write_text(REFERENCE + '\n')
    (skill / 'scripts/run.sh').write_text(SCRIPT)
    (workspace / 'secret.txt').write_text(SECRET)
    (skill / 'escape.txt').symlink_to(workspace / 'secret.txt')


def install_nothing(workspace, state):
    # A repository is not trusted to hand the model instructions, and a run
    # without skills says nothing about them at all.
    (workspace / 'README.md').write_text('no skills here\n')


calls = [
    ('load_skill', {'name': 'demo-skill'}),
    ('read_skill_resource', {'name': 'demo-skill', 'path': 'references/notes.md'}),
    ('read_skill_resource', {'name': 'demo-skill', 'path': '../secret.txt'}),
    ('read_skill_resource', {'name': 'demo-skill', 'path': 'escape.txt'}),
    ('load_skill', {'name': 'missing-skill'}),
]
requests = run(calls, install_skill)
assert len(requests) == len(calls) + 1, len(requests)

# The catalog names what is installed and how to use it; the instructions
# themselves are not in any prompt.
for request in requests:
    prompt = prompt_of(request)
    assert 'demo-skill' in prompt and DESCRIPTION in prompt, prompt
    assert 'load_skill' in prompt and 'read_skill_resource' in prompt
    assert BODY_TAIL not in prompt
for name in ('load_skill', 'read_skill_resource'):
    assert name in tool_names(requests[0]), tool_names(requests[0])

outputs = results_of(requests[-1])
assert len(outputs) == len(calls), outputs
loaded = json.loads(outputs[0])
assert loaded['is_error'] is False
assert loaded['ccr_id'] is None, loaded
text = loaded['output']
assert text.startswith('<skill_content name="demo-skill">\n'), text[:80]
assert BODY_TAIL in text and len(text) > 8192
assert DESCRIPTION not in text
assert 'Skill directory: ' in text and '.zagent/skills/demo-skill' in text
assert 'references/notes.md' in text and 'scripts/run.sh' in text
assert text.rstrip().endswith('</skill_content>')

reference = json.loads(outputs[1])
assert reference['is_error'] is False, reference
assert reference['output'] == REFERENCE + '\n'

for refusal, needle in (
    (outputs[2], 'not a path inside skill'),
    (outputs[3], 'not a path inside skill'),
    (outputs[4], 'no skill is named'),
):
    status = json.loads(refusal)
    assert status['is_error'] is True, status
    assert needle in status['output'], status['output']
    assert 'demo-skill' in status['output']
    assert SECRET not in status['output']
for request in requests:
    assert SECRET not in json.dumps(request), 'a refusal leaked the file outside the skill'

quiet = run([], install_nothing)
assert len(quiet) == 1
assert 'Installed skills:' not in prompt_of(quiet[0])
assert 'demo-skill' not in prompt_of(quiet[0])
assert 'load_skill' not in tool_names(quiet[0]), tool_names(quiet[0])
assert 'read_skill_resource' not in tool_names(quiet[0])

# The user can name a skill themselves: the instructions travel with the
# request, and the model never has to spend a call on them.
mentioned = run([], install_skill, query='$demo-skill summarize the demo numbers')
assert len(mentioned) == 1
text = user_text(mentioned[0])
assert "The user activated the skill 'demo-skill'" in text, text[:200]
assert '<skill_content name="demo-skill">' in text
assert BODY_TAIL in text and 'summarize the demo numbers' in text
assert not results_of(mentioned[0])
assert 'load_skill' in tool_names(mentioned[0])

# A dollar word that names no installed skill is prose, left as it was typed.
prose = run([], install_skill, query='$nope keep this $HOME as it is')
assert len(prose) == 1
text = user_text(prose[0])
assert '<skill_content' not in text, text[:200]
assert '$nope keep this $HOME as it is' in text

print('PASS: skills are catalogued, activated, read from their own directory and left out when none exist')
