# zagent

[中文说明](README.zh-CN.md) · [Documentation](docs/index.md)

A command-line AI agent built with [Zig](https://ziglang.org/). It works on your
machine through tools — reading and editing files, searching a project, running
commands, calling APIs — and keeps the conversation, the plan and its notes
between runs.

## Features

- **Interactive REPL** — a full-screen conversation with the prompt pinned to the
  bottom and a prompt history that ↑/↓ recall across runs; `Ctrl+Z` suspends and
  `fg` redraws the whole record. [Details](docs/ui.md)
- **Single-query mode** — pass a question directly as a CLI argument
- **Tool use** — the agent runs tools to do the work: `bash`, `read`, `write`, `edit`,
  `apply_patch`, `ls`, `rg`/`grep`, `fd`/`find`, `web_search`, `web_fetch`,
  `ask_user`, `plan`, `memory_save`/`memory_search` and `announce_task`.
  [Tools](docs/tools.md) · [Searching](docs/searching.md) ·
  [Patching](docs/patching.md) · [Web search and fetching](docs/web.md)
- **Multi-turn tool chaining** — the agent loops until the task is complete.
  [The agent loop](docs/agent-loop.md)
- **Sub-agents** — hand one self-contained task to a second agent and watch it:
  every self-check interval it reports its progress on the terminal, and at its
  deadline it stops and says what is done and what is left.
  [Sub-agents](docs/subagents.md)
- **MCP servers** — start the servers described in `mcp.json` and give their
  tools to the model beside the built-in ones, loaded on demand.
  [MCP servers](docs/mcp.md)
- **Session plan** — a checklist of the work in progress that survives `/clear`
  and comes back with a resumed session. [Plan](docs/plan.md)
- **Durable conversations** — every launch is a saved session: `/new` starts
  another, `--resume <id>` picks one up with its context and plan.
  [Sessions](docs/sessions.md)
- **Memory** — durable notes scoped to the workspace, written by the model when
  a decision or convention matters, searched on demand. [Memory](docs/memory.md)
- **Choice menus** — when a request is ambiguous, the agent offers concrete
  options instead of guessing, with the recommended one marked.
  [Choices](docs/ui.md#choices)
- **Completion judged by the model** — a final answer ends the turn; the model
  must verify its work and say what is unfinished.
  [Completion status](docs/agent-loop.md#completion-status)
- **Thinking panel** — the model's reasoning scrolls in one dim row above the
  prompt while it thinks, stays a few seconds into the answer, then folds into
  one line. [Thinking](docs/ui.md#thinking)
- **Live progress** — waiting, running a tool and watching a sub-agent each get
  one animated line with the time so far. [Live progress](docs/ui.md#live-progress)
- **Debug tracing** — `--debug` records every request, response, tool call and
  result, and renders the run as one self-contained HTML flowchart to read when
  something went wrong. It is a build option, so a release binary carries none of
  it. [Debug tracing](docs/debug.md)
- **Provider presets** — `openai`, `deepseek`, `openai-compatible` for any
  vendor speaking the Responses API, and `codex` for a ChatGPT subscription.
  [Providers](docs/providers.md) · [ChatGPT / Codex](docs/codex.md)
- **Markdown rendering and ANSI colour** — styled in a terminal, raw markdown
  when piped. [Rendering](docs/ui.md#rendering)

## Requirements

- Zig 0.17.x
- An API key and base URL for a Responses-compatible endpoint

## Build

```bash
zig build
```

The binary is written to `zig-out/bin/zagent`. `zagent --help` lists the flags.

## Quick start

```bash
export DEEPSEEK_API_KEY='your key'      # or OPENAI_API_KEY, see Providers
zagent                                  # interactive session
zagent "what is the current date and time?"   # one query, one answer
zagent --resume <session-id> "Continue the task"
```

Exported keys alone are enough: `DEEPSEEK_API_KEY` selects the `deepseek`
preset, `OPENAI_API_KEY` selects `openai`. For any other vendor:

```bash
export AI_PROVIDER=openai-compatible
export AI_URL=https://dashscope.aliyuncs.com/compatible-mode/v1
export AI_MODEL=qwen-plus
export AI_KEY='your key'
zagent
```

The config file, the full environment table, the token budget and the retries
are in [Configuration](docs/configuration.md). Start with a copy of
`zagent.example.conf` in `$XDG_CONFIG_HOME/zagent` or `~/.config/zagent`;
`mcp.example.json` shows the optional MCP servers.

## Provider presets

| Provider            | Base URL                    | Default model           | API key variable   |
|---------------------|-----------------------------|-------------------------|--------------------|
| `openai`            | `https://api.openai.com/v1` | `gpt-4o-mini`           | `OPENAI_API_KEY`   |
| `deepseek`          | `https://api.deepseek.com`  | `deepseek-flash`        | `DEEPSEEK_API_KEY` |
| `openai-compatible` | *(set with `AI_URL`)*       | *(set with `AI_MODEL`)* | `AI_KEY`           |
| `codex`             | ChatGPT backend             | `gpt-5.4`               | — (`zagent login`) |

An explicit `AI_URL`, `AI_MODEL` or key always wins over the preset, and
`AI_PROVIDER` unset is autodetected from the exported keys. Details, including
autodetection and the Responses API mapping:
[Providers](docs/providers.md).

## Optional prompt cache retention

`AI_PROMPT_CACHE_RETENTION` can be set in the environment or config file
(environment wins). It defaults to unset: no explicit cache field is sent. It
accepts only `in_memory` or `24h`; other values fail configuration loading with
`InvalidPromptCacheRetention`. Confirm support before enabling it on a compatible
endpoint. Automatic server-side caching may work without it.
See [the example config](zagent.example.conf).

Read/search pages hold about 7.5 KiB, and any tool result larger than 8 KiB —
shell output, a fetched page, an MCP answer — is cached in the run's scratch folder
and replaced by a 4 KiB preview naming a cache ID that `ccr_retrieve` reads back.
Cached output is named after its content, so identical output is kept once. Long
shell output keeps both ends of stdout and stderr and marks omitted content. Redirect large output
to a file and read pages when the omitted middle matters. Debug request events
include input bytes, tool schema bytes and a SHA-256 tool-set fingerprint; turn
summaries distinguish missing cache reports from a reported zero.

## REPL commands

| Command       | Description                      |
|---------------|----------------------------------|
| `/help`       | Show help                        |
| `/clear`      | Clear conversation history       |
| `/new`        | Start a new session on a cleared screen |
| `/session`    | Show the current session ID and resume command |
| `/plan`       | Show the plan; `/plan clear` drops it |
| `/memory`     | List saved memories              |
| `/remember <text>` | Save a note to memory        |
| `/forget <n\|all>` | Remove a saved note, or all of them |
| `/model`      | Show the current model           |
| `/status`     | Show token usage and account quota |
| `/mcp`        | List the MCP servers and their tools |
| `/debug`      | Record every step and write an HTML report |
| `/quit`       | Exit                             |

Enter submits, Alt+Enter or Ctrl+J inserts a newline, `Ctrl+Z` suspends, `Ctrl+D`
exits, Esc interrupts a running task, and `/` or `@` open the completion popups.
The keyboard in full: [Interface](docs/ui.md).

## Before you run it

Tools and local MCP servers run directly on the host with your permissions,
environment and network access — there is no sandbox and no command filter.
Start zagent in the intended project, approve each directory once when it asks,
and only run tasks you trust. Read [Security and state](docs/security.md) once
before pointing it at anything unfamiliar.

## Documentation

| Page | Covers |
|------|--------|
| [docs/index.md](docs/index.md) | The full documentation index |
| [Configuration](docs/configuration.md) | Config file, environment variables, output budget, retries |
| [Providers](docs/providers.md) | Presets, autodetection, any Responses-compatible endpoint |
| [ChatGPT / Codex](docs/codex.md) | Subscription login, models, quotas, credentials |
| [Interface](docs/ui.md) | Full-screen session, commands, history, popups, menus, rendering |
| [The agent loop](docs/agent-loop.md) | Tool chaining, completion, how a turn ends |
| [Tools](docs/tools.md) | The built-in tool set and the result limits |
| [Searching](docs/searching.md) | `rg`, `grep`, `fd`, `find` |
| [Patching](docs/patching.md) | `apply_patch` and unified diffs |
| [Web search and fetching](docs/web.md) | The `web_search` and `web_fetch` tools |
| [Sub-agents](docs/subagents.md) | A second agent, its self-checks and its deadline |
| [MCP servers](docs/mcp.md) | `mcp.json` and lazy tool loading |
| [Debug tracing](docs/debug.md) | `--debug`: every step, and the HTML report of a run |
| [Sessions](docs/sessions.md) | Durable conversations, `--resume`, context |
| [Plan](docs/plan.md) | The checklist of the work in progress |
| [Memory](docs/memory.md) | Durable notes between sessions |
| [Security and state](docs/security.md) | Execution policy, trust, state folder, scratch directory |
| [Development](docs/development.md) | Build, tests, project structure |

## Tests

```bash
zig build test              # unit tests
zig build test-integration  # builds the binary, runs the Python suites in tests/
```

Both are described in [Development](docs/development.md#tests).
