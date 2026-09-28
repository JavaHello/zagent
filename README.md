# zagent

A command-line AI agent built with [Zig](https://ziglang.org/) that can help you with any task using an OpenAI-compatible API.

## Features

- **Interactive REPL** — conversational chat loop with history
- **Single-query mode** — pass a question directly as a CLI argument
- **Tool use (function calling)** — the agent can execute tools to help you:
  - `shell` — run shell commands
  - `read_file` — read file contents
  - `write_file` — create or overwrite files
  - `list_dir` — list directory contents
- **Multi-turn tool chaining** — the agent loops until the task is complete
- **Built-in provider presets** — one setting selects `deepseek` or `openai`, autodetected from `OPENAI_API_KEY` / `DEEPSEEK_API_KEY` when unset
- **OpenAI-compatible** — works with any endpoint that speaks the OpenAI chat-completions protocol (OpenAI, Azure OpenAI, Ollama, LM Studio, …)
- **ANSI colour output**

## Requirements

- Zig 0.16.0 or later
- An OpenAI-compatible API key

## Build

```bash
zig build
```

The binary is written to `zig-out/bin/zagent`.

## Configuration

Configuration can be loaded from a config file and/or environment variables. The config file is read from:

- `$XDG_CONFIG_HOME/zagent` (if `XDG_CONFIG_HOME` is set)
- `~/.config/zagent` (fallback)

The file supports `key=value` lines (comments start with `#`). Supported keys are `AI_PROVIDER`, `AI_URL`, `AI_KEY`, `AI_MODEL`, `AI_MAX_TOKENS`, `AI_MAX_ITERATIONS` (or their `OPENAI_*` equivalents). Environment variables override config file values.

See `zagent.example.conf` for a complete example config file.

All configuration is also supported through environment variables:

| Variable           | Default                          | Description                          |
|--------------------|----------------------------------|--------------------------------------|
| `AI_PROVIDER`      | *(autodetected)*                 | Select a built-in preset: `deepseek` or `openai` |
| `OPENAI_API_KEY`   | *(required for OpenAI)*          | Your OpenAI (or compatible) API key  |
| `OPENAI_BASE_URL`  | `https://api.openai.com/v1`      | API base URL                         |
| `OPENAI_MODEL`     | `gpt-4o-mini`                    | Model to use                         |
| `OPENAI_MAX_TOKENS`| `4096`                           | Maximum tokens per response          |
| `OPENAI_MAX_ITERATIONS` | `200`                      | Maximum tool-call loop iterations    |

Every one of these also has a shorter `AI_`-prefixed spelling that works in both the config file and the environment, so `AI_MODEL` and `OPENAI_MODEL` are interchangeable. An explicit value always wins over a value implied by `AI_PROVIDER`.

## Providers

`AI_PROVIDER` selects a built-in preset that supplies the base URL, the default model, and the name of the environment variable holding the API key:

| Provider   | Base URL                     | Default model    | API key variable   |
|------------|------------------------------|------------------|--------------------|
| `openai`   | `https://api.openai.com/v1`  | `gpt-4o-mini`    | `OPENAI_API_KEY`   |
| `deepseek` | `https://api.deepseek.com`   | `deepseek-flash` | `DEEPSEEK_API_KEY` |

To use some other OpenAI-compatible endpoint, leave `AI_PROVIDER` unset and set `AI_URL` / `AI_MODEL` yourself.

Precedence, highest first: an explicit environment variable, then the config file, then the provider preset.

### Autodetection

With no `AI_PROVIDER` in the environment or in the config file, zagent picks a provider from whichever API key your shell already exports:

| Exported               | Selected                                                       |
|------------------------|----------------------------------------------------------------|
| `OPENAI_API_KEY`       | `openai`                                                       |
| `DEEPSEEK_API_KEY`     | `deepseek`                                                     |
| both                   | `openai`                                                       |
| neither                | no provider — the OpenAI defaults apply and startup warns about the missing key |

So `export DEEPSEEK_API_KEY=...` on its own is enough to talk to DeepSeek, and a shell that has exported `OPENAI_API_KEY` resolves exactly as it did before autodetection existed.

A key set in the *config file* turns autodetection off: that key is paired with the configured (or default OpenAI) endpoint, and an unrelated exported variable must not move the endpoint out from under it.

Three deliberate details worth knowing:

- When a provider is selected, only *its* API key variable is consulted. `OPENAI_API_KEY` is ignored under `AI_PROVIDER=deepseek`, so a key exported for other tooling cannot be sent to the wrong endpoint. Use `AI_KEY` if you want one key for every provider.
- `AI_KEY` alone never selects a provider, because it names no host. The endpoint stays the OpenAI default.
- An unknown provider name is a startup error rather than a silent fallback, and the message lists the valid names.

## Usage

### Interactive mode

```bash
export OPENAI_API_KEY=sk-...
./zig-out/bin/zagent
```

```
 ______ _       ___  ___  _____  _   _ _____
|___  //_\     / _ \|  _\| ____|| \ | |_   _|
   / // _ \   | |_| | | _| |__  |  \| | | |
  / // ___ \  |  _  | |_|| |__  | |\  | | |
 /_//_/   \_\ |_| |_|___/|_____||_| \_| |_|
  Model : gpt-4o-mini
  Type /help for commands, Ctrl+D to exit.

you ❯ list all .zig files in the current directory
  ⚙ shell {"command":"find . -name '*.zig' -type f"}
  ✓ ./src/agent.zig
./src/config.zig
...

Assistant
Here are all the .zig files in the current directory: ...
```

### Single-query mode

```bash
export OPENAI_API_KEY=sk-...
./zig-out/bin/zagent "what is the current date and time?"
```

### REPL commands

| Command       | Description                      |
|---------------|----------------------------------|
| `/help`       | Show help                        |
| `/clear`      | Clear conversation history       |
| `/model`      | Show the current model           |
| `/quit`       | Exit                             |
| `Ctrl+D`      | Exit                             |

### Using a local model (Ollama)

```bash
export OPENAI_BASE_URL=http://localhost:11434/v1
export OPENAI_API_KEY=ollama
export OPENAI_MODEL=llama3.2
./zig-out/bin/zagent
```

### Using a custom OpenAI-compatible endpoint

```bash
export OPENAI_BASE_URL=https://your-endpoint/v1
export OPENAI_API_KEY=your-key
export OPENAI_MODEL=your-model
./zig-out/bin/zagent
```

### Using DeepSeek

```bash
export DEEPSEEK_API_KEY=your-deepseek-key
./zig-out/bin/zagent
```

The key alone selects the `deepseek` preset, as described under [Autodetection](#autodetection). Set `AI_PROVIDER=deepseek` as well if you want the choice to be explicit, or if a key in your config file would otherwise turn autodetection off.

DeepSeek enables thinking mode by default, and zagent requests it explicitly rather than relying on that default. The recognised model names are:

| `AI_MODEL`          | Sent to the API      | Thinking mode |
|---------------------|----------------------|---------------|
| `deepseek-flash`    | `deepseek-flash`     | enabled       |
| `deepseek-v4-pro`   | `deepseek-v4-pro`    | enabled       |
| `deepseek-chat`     | `deepseek-flash`     | disabled      |
| `deepseek-reasoner` | `deepseek-flash`     | enabled       |
| `deepseek-v4-flash` | `deepseek-flash`     | disabled      |

Any other model name is sent through unchanged with no `thinking` field. For the fastest and cheapest replies, use `AI_MODEL=deepseek-chat`, which turns thinking off.

## Run tests

```bash
zig build test
```

## Project structure

```
src/
  main.zig     — CLI entry point, REPL loop
  config.zig   — Configuration loading from the config file and environment
  provider.zig — Built-in provider presets
  openai.zig   — OpenAI-compatible HTTP client and JSON serialisation
  tools.zig   — Tool implementations (shell, read_file, write_file, list_dir)
  agent.zig   — Agent loop: call API → execute tools → repeat
build.zig     — Zig build script
```
