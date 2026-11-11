# Providers

zagent talks to one protocol: the Responses API. `AI_PROVIDER` picks a built-in
preset that supplies the base URL, the default model, and the name of the
environment variable holding the API key. Anything you set explicitly wins over
the preset.

## Presets

| Provider            | Base URL                    | Default model           | API key variable   |
|---------------------|-----------------------------|-------------------------|--------------------|
| `openai`            | `https://api.openai.com/v1` | `gpt-4o-mini`           | `OPENAI_API_KEY`   |
| `deepseek`          | `https://api.deepseek.com`  | `deepseek-flash`        | `DEEPSEEK_API_KEY` |
| `openai-compatible` | *(set with `AI_URL`)*       | *(set with `AI_MODEL`)* | `AI_KEY`           |
| `codex`             | ChatGPT backend (see [ChatGPT / Codex](codex.md)) | `gpt-5.4` | — (`zagent login`) |

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
| both                   | `openai`                                                       |
| neither                | no provider — the OpenAI defaults apply and startup warns about the missing key |

So `export DEEPSEEK_API_KEY=...` on its own is enough to talk to DeepSeek, and a
shell that has exported `OPENAI_API_KEY` resolves exactly as it did before
autodetection existed.

Three deliberate details:

- `openai-compatible` is never autodetected, even though `AI_KEY` is its key
  variable: a generic key names no host, so the endpoint has to be chosen
  explicitly.
- A key set in the *config file* turns autodetection off: that key is paired
  with the configured (or default OpenAI) endpoint, and an unrelated exported
  variable must not move the endpoint out from under it.
- `AI_KEY` alone never selects a provider. The endpoint stays the OpenAI
  default.

## Any Responses-compatible endpoint

`openai-compatible` is the preset for every other vendor — Alibaba Cloud Model
Studio (百炼), Moonshot, Zhipu, a self-hosted vLLM or LiteLLM gateway, and so on.
It assumes no host of its own: `AI_URL` and `AI_MODEL` are required, the key
comes from `AI_KEY`, and startup names the setting that is still missing. The
spelling is matched case-insensitively, and `openai_compatible` and `compatible`
are accepted too.

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

## DeepSeek

```bash
export DEEPSEEK_API_KEY=your-deepseek-key
zagent
```

The key alone selects the `deepseek` preset, as described under
[Autodetection](#autodetection). Set `AI_PROVIDER=deepseek` as well if you want
the choice to be explicit, or if a key in your config file would otherwise turn
autodetection off.

## How the protocol is used

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

There is no automatic fallback to Chat Completions. Protocol mapping follows the
[official Responses migration guide](https://developers.openai.com/api/docs/guides/migrate-to-responses).

## ChatGPT subscription

The `codex` preset uses the ChatGPT backend with a device-code login instead of
an API key; it has its own page: [ChatGPT / Codex](codex.md).
