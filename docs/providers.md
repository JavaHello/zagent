# Providers

zagent speaks two protocols. Most endpoints use the OpenAI **Responses API**;
Anthropic's endpoint and the gateways that copy it use the **Messages API**.
`AI_PROVIDER` picks a built-in preset that supplies the base URL, the default
model, the name of the environment variable holding the API key, and the
protocol that goes with them. Anything you set explicitly wins over the preset.

## Presets

| Provider               | Protocol    | Base URL                    | Default model      | API key variable   |
|------------------------|-------------|-----------------------------|--------------------|--------------------|
| `openai`               | `responses` | `https://api.openai.com/v1` | `gpt-4o-mini`      | `OPENAI_API_KEY`   |
| `deepseek`             | `responses` | `https://api.deepseek.com`  | `deepseek-flash`   | `DEEPSEEK_API_KEY` |
| `anthropic`            | `messages`  | `https://api.anthropic.com/v1` | `claude-sonnet-4-5` | `ANTHROPIC_API_KEY` |
| `openai-compatible`    | `responses` | *(set with `AI_URL`)*       | *(set with `AI_MODEL`)* | `AI_KEY`      |
| `anthropic-compatible` | `messages`  | *(set with `AI_URL`)*       | *(set with `AI_MODEL`)* | `AI_KEY`      |
| `codex`                | `responses` | ChatGPT backend (see [ChatGPT / Codex](codex.md)) | `gpt-5.4` | — (`zagent login`) |

An unknown provider name is a startup error rather than a silent fallback, and
the message lists the valid names.

## Precedence

Highest first:

1. an explicit environment variable,
2. the config file,
3. the provider preset.

Only the selected provider's key variable is consulted. `OPENAI_API_KEY` is
ignored under `AI_PROVIDER=deepseek`, so a key exported for other tooling cannot
be sent to the wrong endpoint. `AI_KEY` alone never selects a provider, because
it names no host.

## Autodetection

With no `AI_PROVIDER` in the environment or in the config file, zagent picks a
provider from whichever API key your shell already exports:

| Exported               | Selected                                                       |
|------------------------|----------------------------------------------------------------|
| `OPENAI_API_KEY`       | `openai`                                                       |
| `DEEPSEEK_API_KEY`     | `deepseek`                                                     |
| `ANTHROPIC_API_KEY`    | `anthropic`                                                    |
| more than one          | the first of `openai`, `deepseek`, `anthropic` that is exported |
| neither                | no provider — the OpenAI defaults apply and startup warns about the missing key |

So `export DEEPSEEK_API_KEY=...` on its own is enough to talk to DeepSeek, and a
shell that has exported `OPENAI_API_KEY` resolves exactly as it did before
autodetection existed.

Three deliberate details:

- The two `-compatible` presets are never autodetected, even though `AI_KEY` is
  their key variable: a generic key names no host, so the endpoint has to be
  chosen explicitly.
- A key set in the *config file* turns autodetection off: that key is paired
  with the configured (or default OpenAI) endpoint, and an unrelated exported
  variable must not move the endpoint out from under it.
- `AI_KEY` alone never selects a provider. The endpoint stays the OpenAI
  default.

## Any Responses-compatible endpoint

`openai-compatible` is the preset for every other vendor speaking the Responses
API — Alibaba Cloud Model Studio (百炼), Moonshot, Zhipu, a self-hosted vLLM or
LiteLLM gateway, and so on. It assumes no host of its own: `AI_URL` and
`AI_MODEL` are required, the key comes from `AI_KEY`, and startup names the
setting that is still missing. The spelling is matched case-insensitively, and
`openai_compatible` and `compatible` are accepted too.

```bash
export AI_PROVIDER=openai-compatible
export AI_URL=https://dashscope.aliyuncs.com/compatible-mode/v1
export AI_MODEL=qwen-plus
export AI_KEY=sk-your-dashscope-key
zagent
```

The endpoint must implement the Responses API: the client posts to
`<AI_URL>/responses` and lists `/models`, with no fallback to Chat Completions.
A Chat Completions-only endpoint has to be replaced with a Responses-compatible
one.

## Any Messages-compatible endpoint

`anthropic-compatible` is the same idea for vendors speaking the Anthropic
Messages API: Kimi, Zhipu, MiniMax, a gateway that fronts several vendors, or a
self-hosted proxy. It names no host either, so `AI_URL` and `AI_MODEL` are
required and the key comes from `AI_KEY`. `anthropic_compatible` and
`messages-compatible` are accepted spellings.

```bash
export AI_PROVIDER=anthropic-compatible
export AI_URL=https://api.moonshot.cn/anthropic
export AI_MODEL=kimi-k2-turbo-preview
export AI_KEY=sk-your-moonshot-key
zagent
```

The client posts to `<AI_URL>/messages` and lists `<AI_URL>/models`. The
endpoint has to speak the Messages API: a Chat Completions or Responses-only
endpoint is a different preset.

## Anthropic

```bash
export ANTHROPIC_API_KEY=sk-ant-...
zagent
```

The key alone selects the preset, as described under
[Autodetection](#autodetection). `AI_URL` defaults to `https://api.anthropic.com/v1`
and `AI_MODEL` to `claude-sonnet-4-5`; both can be overridden the usual way. Set
`AI_PROVIDER=anthropic` as well if you want the choice to be explicit, or if a
key in your config file would otherwise turn autodetection off.

## DeepSeek

```bash
export DEEPSEEK_API_KEY=your-deepseek-key
zagent
```

The key alone selects the `deepseek` preset, as described under
[Autodetection](#autodetection). Set `AI_PROVIDER=deepseek` as well if you want
the choice to be explicit, or if a key in your config file would otherwise turn
autodetection off.

## How the Responses protocol is used

`AI_URL` is the API base URL (for example `https://api.openai.com/v1` or
`https://api.deepseek.com`), without the `/responses` suffix. `AI_MODEL` is sent
unchanged, so vendor-specific model names stay under your control.

The client uses `max_output_tokens`, flat function definitions, and typed
`function_call` / `function_call_output` items linked with `call_id`. Requests
set `store: false` and request `reasoning.encrypted_content`. Every returned
output item is retained and replayed, including reasoning and function item IDs;
durable sessions preserve them across restarts, see
[Sessions](sessions.md#durable-conversations). Older sessions are converted to
Responses input messages and call/output pairs. Legacy free-form
`reasoning_content` strings are not sent as a Responses reasoning item.

`AI_REASONING_EFFORT` and `AI_PROMPT_CACHE_RETENTION` are standard Responses
fields, so any provider gets them as outer-level members when they are set. On
the OpenAI and Codex backends an effort also asks for `reasoning.summary:
"auto"`, which is what makes them narrate their reasoning to the terminal's
[thinking panel](ui.md#thinking); DeepSeek streams its own reasoning text
unasked, and a generic compatible endpoint is not sent the member at all;
`AI_SERVICE_TIER` is Codex's fast mode and is sent only there. See
[Environment variables](configuration.md#environment-variables).

`thinking` is DeepSeek's own switch, and the spelling the compatible endpoints
use for the same idea, so those two presets ask for it by default
(`"thinking":{"type":"enabled"}`) and `AI_THINKING=disabled` asks for the
non-thinking mode explicitly — DeepSeek keeps thinking on when the field is
missing. The OpenAI API and the Codex backend do not define the member, so they
send nothing unless `AI_THINKING` is set for them by name. Use
`AI_THINKING=omit` to drop it again for a compatible endpoint that rejects it.

There is no automatic fallback to Chat Completions. Protocol mapping follows the
[official Responses migration guide](https://developers.openai.com/api/docs/guides/migrate-to-responses).

## How the Messages protocol is used

The client posts to `<AI_URL>/messages` with the key in `x-api-key` and
`anthropic-version: 2023-06-01`, and requests a stream. `AI_MODEL` is sent
unchanged; `AI_MAX_TOKENS` becomes the required `max_tokens`.

The same conversation is projected onto the API's own shapes:

- the system prompt is a top-level `system` string, not a message;
- a tool result becomes a `tool_result` block in a *user* message, and the
  results of one assistant turn are merged into a single user message, because
  the API wants strictly alternating roles;
- a tool is offered as `{name, description, input_schema}` instead of a
  Responses function; a schema that leaves out `"type": "object"` — possible in
  a hand-written MCP definition — is given one;
- the reply arrives as typed content blocks. Text is the answer, `thinking`
  blocks go to the [thinking panel](ui.md#thinking), and `tool_use` blocks
  become the tool calls the agent runs.

The blocks of every reply are kept exactly as they were streamed, signed
thinking included, and replayed on later turns instead of being rebuilt from the
summary fields. Because a thinking block's signature is only valid for a request
that asks for thinking, those blocks are replayed only when
`AI_THINKING=enabled` is in force; a session resumed with thinking off sends the
text and calls alone.

`AI_THINKING=enabled` is the switch here, since the API thinks only when told
to. It reserves `AI_MAX_TOKENS / 2` as `thinking.budget_tokens`, which leaves the
other half for the answer itself; a request whose `max_tokens` is below 2048 has
no room for the API's thousand-token floor and is sent without thinking.
`AI_THINKING=disabled` and `omit` both send nothing.

`AI_REASONING_EFFORT`, `AI_SERVICE_TIER` and `AI_PROMPT_CACHE_RETENTION` are
Responses-only fields and are not sent to a Messages endpoint. Token usage is
read from the API's own counters: the cached part of the prompt
(`cache_read_input_tokens`, `cache_creation_input_tokens`) is counted inside the
input the terminal reports, so the input figure is the whole prompt and the
cached figure names the part of it that came from the cache.

A reply cut off by `max_tokens` is read like a truncated Responses reply: its
text is kept and continued, and a tool call whose arguments were still arriving
is dropped rather than executed or replayed.

## ChatGPT subscription

The `codex` preset uses the ChatGPT backend with a device-code login instead of
an API key; it has its own page: [ChatGPT / Codex](codex.md).
