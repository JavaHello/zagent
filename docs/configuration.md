# Configuration

zagent reads one config file and the environment. Nothing else is required to
start.

## Config file

The file is read from:

- `$XDG_CONFIG_HOME/zagent` (if `XDG_CONFIG_HOME` is set)
- `~/.config/zagent` (fallback)

It holds `key=value` lines, and comments start with `#`. The keys are the
`AI_*` and `WEB_*` names below, and an environment variable always overrides
the same key from the file.

The file sits next to two neighbours: `mcp.json`, which describes MCP servers
(see [MCP servers](mcp.md)), and `codex-auth.json`, which holds ChatGPT
credentials (see [ChatGPT / Codex](codex.md)).

`zagent.example.conf` in the repository root is a complete commented example,
and `mcp.example.json` shows every member an MCP entry takes.

## Environment variables

| Variable            | Default                             | Description                                     |
|---------------------|-------------------------------------|-------------------------------------------------|
| `AI_PROVIDER`       | *(autodetected)*                    | Built-in preset: `deepseek`, `anthropic`, `openai`, `openai-compatible`, `anthropic-compatible`, `codex`; see [Providers](providers.md) |
| `AI_KEY`            | *(optional)*                        | API key for the selected endpoint               |
| `OPENAI_API_KEY`    | *(required for OpenAI)*             | OpenAI (or compatible) API key                  |
| `DEEPSEEK_API_KEY`  | *(required for DeepSeek)*           | DeepSeek API key                                |
| `ANTHROPIC_API_KEY` | *(required for Anthropic)*          | Anthropic API key                               |
| `AI_URL`            | `https://api.openai.com/v1`         | API base URL, without `/responses` or `/messages` |
| `AI_MODEL`          | `gpt-4o-mini`                       | Model name, sent unchanged                      |
| `AI_MAX_TOKENS`     | `8192`                              | Initial output token budget per response (`max_output_tokens`, or `max_tokens` for the Messages API) |
| `AI_REASONING_EFFORT` | *(unset)*                         | Responses API only: sent as a top-level `reasoning.effort`; OpenAI and Codex are also asked for a reasoning summary |
| `AI_SERVICE_TIER`   | *(unset)*                           | Codex only: sent as `service_tier`              |
| `AI_CODEX_CLIENT_VERSION` | the version this build was written against | Codex only: the CLI version reported to `/models`, which decides which models that list offers |
| `AI_PROMPT_CACHE_RETENTION` | *(unset)*                   | Responses API only: sent as `prompt_cache_retention`; `in_memory` or `24h` |
| `AI_THINKING`       | `enabled` for `deepseek` and `openai-compatible`, otherwise omitted | Thinking switch: `enabled`, `disabled`, or `omit`. On the Messages API, `enabled` reserves `AI_MAX_TOKENS / 2` for a thinking budget |
| `AI_MEMORY_FILE`    | Global workspace state: `memory.md` | Override where the notes are stored             |
| `AI_SKILLS_DIRS`    | *(unset)*                           | Extra [skill](skills.md#where-skills-are-found) directories, colon-separated; a leading `~/` is expanded |
| `AI_DEBUG`          | *(unset)*                           | Any value but `0`/`false`/`off`/`no` records a debug trace; see [Debug tracing](debug.md) |
| `WEB_SEARCH_URL`    | *(unset — DuckDuckGo)*              | Endpoint `web_search` puts a query to, with `{query}` and `{limit}` filled in |
| `WEB_SEARCH_KEY`    | *(unset)*                           | Sent to that endpoint as `Authorization: Bearer` |
| `WEB_FETCH_URL`     | *(unset — the page itself)*         | Fetch service `web_fetch` asks for a page, with `{url}` filled in or the address appended |
| `WEB_FETCH_KEY`     | *(unset)*                           | Sent to that service as `Authorization: Bearer` |

Provider-specific API keys (`OPENAI_API_KEY`, `DEEPSEEK_API_KEY`, `ANTHROPIC_API_KEY`) are read from
the environment; use `AI_KEY` in the config file when you want one key for
every provider. An explicit value always wins over the provider preset —
see [Precedence](providers.md#precedence).

## The web tools' services

`WEB_SEARCH_URL` and `WEB_FETCH_URL` are the endpoints `web_search` and
`web_fetch` ask instead of their built-in behaviour; left unset, a search goes
to DuckDuckGo's own results page and a page is fetched and read as text here.
Both take a key as a bearer token. See
[Web search and fetching](web.md) for the placeholders and the shapes of answer
each of them reads.

## Output budget and truncation

The budget is spelled per protocol: `AI_MAX_TOKENS` is the initial
`max_output_tokens` of a Responses request and the `max_tokens` of a Messages
one, which is where `AI_THINKING=enabled` takes its thinking budget from.

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

Transient network errors (`HttpConnectionClosing`, a reset connection, a broken
pipe, a timeout, an unreachable network, a name lookup no nameserver answered
for) and HTTP 408/429/500/502/503/504 responses are retried, up to three
attempts with a one and then two second pause, each attempt on a fresh
connection. A retry is only sent while no answer text has been shown; a stream
that fails after the reply started ends the turn with its error. A request that
fails while it is being written is retried the same way: the reason behind
`WriteFailed` is read off the connection, and the dead socket is dropped rather
than pooled for the next request. Output still cut off after bounded
continuations returns an error instead of reporting completion.

## Session and workspace state

Trust approvals, memory and session snapshots are not configured by these keys:
they live in a global, per-directory state folder. See
[Security and state](security.md#directory-trust-and-global-state).
