# Configuration

zagent reads one config file and the environment. Nothing else is required to
start.

## Config file

The file is read from:

- `$XDG_CONFIG_HOME/zagent` (if `XDG_CONFIG_HOME` is set)
- `~/.config/zagent` (fallback)

It holds `key=value` lines, and comments start with `#`. The keys are the
`AI_*` names below, and an environment variable always overrides the same key
from the file.

The file sits next to two neighbours: `mcp.json`, which describes MCP servers
(see [MCP servers](mcp.md)), and `codex-auth.json`, which holds ChatGPT
credentials (see [ChatGPT / Codex](codex.md)).

`zagent.example.conf` in the repository root is a complete commented example,
and `mcp.example.json` shows every member an MCP entry takes.

## Environment variables

| Variable            | Default                             | Description                                     |
|---------------------|-------------------------------------|-------------------------------------------------|
| `AI_PROVIDER`       | *(autodetected)*                    | Built-in preset: `deepseek`, `openai`, `openai-compatible`, `codex`; see [Providers](providers.md) |
| `AI_KEY`            | *(optional)*                        | API key for the selected endpoint               |
| `OPENAI_API_KEY`    | *(required for OpenAI)*             | OpenAI (or compatible) API key                  |
| `DEEPSEEK_API_KEY`  | *(required for DeepSeek)*           | DeepSeek API key                                |
| `AI_URL`            | `https://api.openai.com/v1`         | API base URL, without `/responses`              |
| `AI_MODEL`          | `gpt-4o-mini`                       | Model name, sent unchanged                      |
| `AI_MAX_TOKENS`     | `8192`                              | Initial output token budget per response        |
| `AI_REASONING_EFFORT` | *(unset)*                         | Codex only: sent as `reasoning.effort`          |
| `AI_SERVICE_TIER`   | *(unset)*                           | Codex only: sent as `service_tier`              |
| `AI_MEMORY_FILE`    | Global workspace state: `memory.md` | Override where the notes are stored             |
| `AI_DEBUG`          | *(unset)*                           | Any value but `0`/`false`/`off`/`no` records a debug trace; see [Debug tracing](debug.md) |

Provider-specific API keys (`OPENAI_API_KEY`, `DEEPSEEK_API_KEY`) are read from
the environment; use `AI_KEY` in the config file when you want one key for
every provider. An explicit value always wins over the provider preset —
see [Precedence](providers.md#precedence).

## Output budget and truncation

`AI_MAX_TOKENS` is the initial `max_output_tokens` of a Responses request.

When a response hits `max_output_tokens`, the main conversation retries the
same input with a doubled token budget, up to three retries and a growth cap of
8192 tokens — the most DeepSeek's chat models accept. Since the default budget
already equals that cap, the retry only grows a smaller configured
`AI_MAX_TOKENS`. Partial tool calls are discarded and completed tool results are
retained.

If the reply is still cut off, zagent keeps the partial text and asks the model
to continue exactly where it stopped, up to eight times; a cut-off tool call is
instead re-asked as a request to work in smaller steps, twice. Only when that
also fails does the turn end with `ResponseTruncated`, after printing what was
produced.

## Retries

Transient network errors and HTTP 408/429/500/502/503/504 responses are retried
up to three attempts. Output still cut off after bounded continuations returns
an error instead of reporting completion.

## Session and workspace state

Trust approvals, memory and session snapshots are not configured by these keys:
they live in a global, per-directory state folder. See
[Security and state](security.md#directory-trust-and-global-state).
