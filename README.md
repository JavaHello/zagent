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
- **OpenAI-compatible** — works with any endpoint that speaks the OpenAI chat-completions protocol (OpenAI, Azure OpenAI, Ollama, LM Studio, …)
- **ANSI colour output**

## Requirements

- Zig 0.15.2 or later
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

The file supports `key=value` lines (comments start with `#`). Supported keys are `AI_URL`, `AI_KEY`, `AI_MODEL`, `AI_MAX_TOKENS` (or their `OPENAI_*` equivalents). Environment variables override config file values.

See `zagent.example.conf` for a complete example config file.

All configuration is also supported through environment variables:

| Variable           | Default                          | Description                          |
|--------------------|----------------------------------|--------------------------------------|
| `OPENAI_API_KEY`   | *(required)*                     | Your OpenAI (or compatible) API key  |
| `OPENAI_BASE_URL`  | `https://api.openai.com/v1`      | API base URL                         |
| `OPENAI_MODEL`     | `gpt-4o-mini`                    | Model to use                         |
| `OPENAI_MAX_TOKENS`| `4096`                           | Maximum tokens per response          |

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

### Using DeepSeek V4

```bash
export OPENAI_BASE_URL=https://api.deepseek.com
export OPENAI_API_KEY=your-deepseek-key
export OPENAI_MODEL=deepseek-v4-flash
./zig-out/bin/zagent
```

`deepseek-v4-pro` is also supported. For backward compatibility, `deepseek-chat` is treated as `deepseek-v4-flash`, and `deepseek-reasoner` is treated as `deepseek-v4-flash` with thinking mode enabled.

## Run tests

```bash
zig build test
```

## Project structure

```
src/
  main.zig    — CLI entry point, REPL loop
  config.zig  — Configuration loading from environment variables
  openai.zig  — OpenAI-compatible HTTP client and JSON serialisation
  tools.zig   — Tool implementations (shell, read_file, write_file, list_dir)
  agent.zig   — Agent loop: call API → execute tools → repeat
build.zig     — Zig build script
```
