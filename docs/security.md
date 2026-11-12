# Security and state

zagent has no sandbox and no command safety filter. Read this page once before
giving it an unfamiliar repository or an unfamiliar task.

## Tool execution policy

All built-in filesystem, search, HTTP and shell tools run directly in the
current working directory. They inherit the host environment (including
credentials), filesystem permissions and network access. Start zagent in the
intended project and only run trusted tasks.

Tools can modify the host system with the current user's permissions. Local MCP
servers also run directly and inherit the host environment; configured `env`
entries add or override variables, see [MCP servers](mcp.md).

Tool calls retain a 180-second default limit (`bash.timeout_seconds` accepts
1–3600), output bounds and process-group cleanup. Commands use
`bash --noprofile --norc -c`, not `/bin/sh`. Output bounds are described in
[Tools](tools.md#output-limit).

```sh
cd /path/to/project
AI_PROVIDER=deepseek zagent "Analyze this project and update its documentation"
zagent "Download the public API documentation and summarize it"
```

## The machine, named in the prompt

Startup reads what machine the run is on and names it in the system prompt: the
operating system and its version (the distribution's `PRETTY_NAME` on Linux,
`ProductVersion` on macOS), the kernel release, the architecture, the CPU count
and the total memory. It is read once, like the search programs: a
[sub-agent](subagents.md) works on the same machine and inherits it.

The agent is told that shell commands run with `bash` there, so it uses that
system's package manager, paths and toolchain and checks which programs it has
instead of assuming another machine's setup. Nothing in the note is an
instruction to act on the host — it is what the host is.

## Scratch directory

Every run creates one private scratch directory at startup (mode `0700`, a
random name under `$TMPDIR`, or `/tmp` if unset) and names it, together with the
working directory, in the system prompt.

The agent is told to use it for complex or multi-step work and for anything that
would change the user's system, settings or configuration, so the workspace and
the host stay untouched; only the finished deliverable is copied back. Existing
tools such as `write`, `read`, `apply_patch` and `bash` work there, so no
separate file API is needed.

The directory is temporary, not durable: it belongs to the process, so agents
started at the same time never share a path and a resumed session gets a fresh
one instead of adopting an old one; `/new` empties it while keeping the path the
system prompt names; and the whole tree, files included, is deleted at exit. The
model may also delete the directory, or whatever it left in it, itself. Anything
worth keeping has to be copied into the workspace or saved with
[`memory_save`](memory.md) before the run ends. The directory is not saved with the
session (`/status` shows the current path).

These are ordinary host directories, not sandboxes or an extra authorization
boundary.

## Directory trust and global state

On first use in a directory, zagent asks whether you trust it before loading
workspace data, making API requests or starting MCP servers. Type `yes` in a
terminal to approve; any other response exits. Piped input cannot grant trust.
Later launches in that directory reuse the saved approval. Approve a directory
interactively before using zagent there in scripts or pipelines.

Trust, memory and sessions are stored globally, separated by canonical
directory:

```text
$XDG_STATE_HOME/zagent/workspaces/<sha256-of-canonical-path>/
  trusted             # full canonical path, checked when loading approval
  memory.md
  sessions/<id>.json
  debug/<session-id>-<epoch>.jsonl, .html   # only with --debug, see Debug tracing
```

Without `XDG_STATE_HOME`, the base is `~/.local/state`. Symlink aliases share
state; different directories do not. Moving a project gives it a new identity.
Delete its `trusted` file to require approval again. Trust is consent to the
execution policy above, not arbitrary-code isolation. Help, version and `models`
management do not require workspace approval.

Project-local `.zagent/` memory and sessions are not read or migrated.

Prompt history lives beside the workspaces, in
`$XDG_STATE_HOME/zagent/history`, see
[Interface](ui.md#prompt-history). ChatGPT credentials live in
`$HOME/.config/zagent/codex-auth.json`, see [ChatGPT / Codex](codex.md).
