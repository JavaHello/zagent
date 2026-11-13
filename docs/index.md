# zagent documentation

The entry point is the [README](../README.md): what zagent is, what it can do,
how to build it and how to run it. This folder holds the details behind that
overview.

## Start here

| Page | Read it when |
|------|--------------|
| [Configuration](configuration.md) | You are setting the config file, the environment variables, the output budget or the retries |
| [Providers](providers.md) | You need to pick or autodetect a provider, or point zagent at any Responses-compatible endpoint |
| [ChatGPT / Codex](codex.md) | You want to use a ChatGPT subscription with `zagent login` |
| [Interface](ui.md) | You want to know what the screen, the prompt and the keyboard do |

## How it works

| Page | Covers |
|------|--------|
| [The agent loop](agent-loop.md) | Tool chaining, how a turn ends, retries |
| [Tools](tools.md) | The built-in tool set, `bash`, `read`, `write`, `edit`, `ls`, and the result limits |
| [Searching](searching.md) | `rg`, `grep`, `fd`, `find` and how the programs are selected |
| [Patching](patching.md) | `apply_patch`, Git unified diffs, permissions and renames |
| [Web search and fetching](web.md) | The `web_search` and `web_fetch` tools, their services, redirects and limits |
| [Sub-agents](subagents.md) | Handing a task to a second agent, its self-checks and deadline |
| [MCP servers](mcp.md) | `mcp.json`, lazy tool loading and the protocol zagent speaks |
| [Debug tracing](debug.md) | `--debug`: every request, response and tool call, and the HTML report of a run |

## What survives a turn

| Page | Covers |
|------|--------|
| [Sessions](sessions.md) | Durable conversations, `--resume`, and what happens to context |
| [Plan](plan.md) | The checklist of the work in progress |
| [Memory](memory.md) | Durable notes between sessions and how they are found |

## Running it safely

| Page | Covers |
|------|--------|
| [Security and state](security.md) | Execution policy, directory trust, the global state folder, the scratch directory |

## Working on zagent

| Page | Covers |
|------|--------|
| [Development](development.md) | Build, tests and the project structure |
