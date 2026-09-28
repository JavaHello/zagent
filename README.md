# zagent

A command-line AI agent built with [Zig](https://ziglang.org/) that can help you with any task using an OpenAI-compatible API.

## Features

- **Interactive REPL** — conversational chat loop, with a prompt history that ↑/↓ recall across runs
- **Single-query mode** — pass a question directly as a CLI argument
- **Tool use (function calling)** — the agent can execute tools to help you:
  - `shell` — run shell commands
  - `read_file` — read file contents
  - `write_file` — create or overwrite files
  - `list_dir` — list directory contents
  - `grep` — search file contents, using `rg` where it is installed
  - `find` — find files by name, using `fd` where it is installed
  - `http_request` — fetch a URL or call an API, without shelling out to `curl`
  - `ask_user` — put a question to you as a numbered list of options
- **Multi-turn tool chaining** — the agent loops until the task is complete
- **Completion check** — after a turn that used tools, an independent judge request decides whether your request is really finished, and sends the agent back to work when it is not
- **Choice menus** — when a request is ambiguous, the agent offers concrete options to choose from instead of guessing, with the one it recommends marked
- **Live progress** — waiting for the model, and running a tool, each get one animated line (`⠋ shell… 8s`) with the time so far, so a long wait never looks like a hang. Off unless both stdout and stderr are a terminal, where the line can be taken and given back
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

The file supports `key=value` lines (comments start with `#`). Supported keys are `AI_PROVIDER`, `AI_URL`, `AI_KEY`, `AI_MODEL`, `AI_MAX_TOKENS`, `AI_MAX_ITERATIONS`, `AI_MAX_VERIFICATIONS`, `AI_MARKDOWN` (or their `OPENAI_*` equivalents). Environment variables override config file values.

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
| `OPENAI_MAX_VERIFICATIONS` | `3`                     | Completion checks per query; `0` disables the check |
| `AI_MARKDOWN`      | `true`                           | Render assistant markdown in a terminal |

Every one of these also has a shorter `AI_`-prefixed spelling that works in both the config file and the environment, so `AI_MODEL` and `OPENAI_MODEL` are interchangeable. An explicit value always wins over a value implied by `AI_PROVIDER`. `AI_MARKDOWN` is the exception: it is not a provider setting and has no `OPENAI_` spelling.

## Rendering

Replies are markdown, and in a terminal they are rendered rather than printed as literal markers: headings, emphasis, inline code and fenced blocks get styling, lists and quotes get a prefix, and lines that carry a prefix wrap with a hanging indent so continuation lines never fall back to the left margin. Tables are laid out in columns, with `:---`, `:---:` and `---:` honoured and cells wrapped inside their column when the table is wider than the terminal. Plain paragraphs are left to the terminal's own soft-wrap.

Output that is not a terminal — piped, redirected, or under `TERM=dumb` — gets the raw markdown instead, so `zagent "..." > notes.md` and `zagent "..." | grep` see exactly what the model wrote. Set `AI_MARKDOWN=0` to turn rendering off in a terminal as well.

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

  ⟳ checking completion…
  ✓ completion check passed
```

### Prompt history

↑ and ↓ walk back and forward through the prompts of this session and earlier ones. The history is read at startup and rewritten after every accepted prompt, from:

- `$XDG_STATE_HOME/zagent/history` (if `XDG_STATE_HOME` is set)
- `~/.local/state/zagent/history` (fallback)

It holds the last 100 entries, and is created with mode `0600`: a prompt can contain anything you were willing to type at it. Entries longer than 4 KB are still recalled in the session that typed them, but are not written, so one pasted blob cannot push everything else out of the file. Lines piped in on stdin are not history and are never stored, and if the file cannot be written the session carries on without it.

### Single-query mode

```bash
export OPENAI_API_KEY=sk-...
./zig-out/bin/zagent "what is the current date and time?"
```

### Completion check

A turn ends when the model stops calling tools and prints an answer — which is
only the model's own opinion that the work is done. zagent asks a second,
independent question about it: after every turn that used at least one tool, it
sends the user's request plus a summary of the work (tool calls, short tool
results, the final answer) to the model with no tools advertised, and expects

```json
{"complete": false, "reason": "The tests were never run.", "next_step": "Run zig build test."}
```

An unfinished verdict is printed and fed back into the conversation, and the
agent keeps working. Up to `AI_MAX_VERIFICATIONS` checks are made per query
(3 by default); the budget is printed when it runs out, and `AI_MAX_VERIFICATIONS=0`
turns the check off. A turn that used no tools is never checked, and neither is
a turn whose answer reports a genuine blocker — a missing credential or an
unreachable service is a finished turn, not a reason to loop.

Two things worth knowing:

- The check costs one extra request per tool-using turn, and it re-sends a
  summary of that turn rather than the whole history.
- If the judge request fails or its reply cannot be read, the turn keeps the
  answer it already printed. A broken checker must not trap the agent in a loop
  that can never pass.

### Choices

When a request is ambiguous — several reasonable approaches, unclear scope, a
decision only you can make — the agent calls `ask_user` and you get a menu:

```
  Which approach should I use?
    1) Rewrite in place  Keeps the history intact. (recommended)
    2) New file  Leaves the original alone.
  Enter takes option 1; type a number, or your own answer.
choice ❯
```

Enter accepts the recommended option, a number picks another one, and anything
else is passed to the agent as your own words. The judge can ask the same way:
when it decides the work is blocked on a decision, it returns the options
itself and you get the same menu. With no terminal to type at (piped input,
single-query mode) the recommended option is taken and the agent says so.

### HTTP requests

`http_request` fetches a URL or calls an API without going through `curl`,
returning the status line, the response headers, and the body:

```
you ❯ fetch https://httpbin.org/json and tell me the content type
  ⚙ http_request {"url":"https://httpbin.org/json"}
  ✓ HTTP/1.1 200 OK
    Date: Mon, 28 Sep 2026 06:21:24 GMT
    Content-Type: application/json
    Content-Length: 429
    ...

    {"slideshow": {"title": "Sample Slide Show", ...}}
```

| Argument  | Required | Description                                                          |
|-----------|----------|----------------------------------------------------------------------|
| `url`     | yes      | The full URL, including the scheme                                    |
| `method`  | no       | `GET` (the default), `HEAD`, `POST`, `PUT`, `PATCH`, `DELETE`, `OPTIONS` |
| `headers` | no       | Request headers as name/value pairs                                   |
| `body`    | no       | Request body, for a method that takes one                             |
| `save_to` | no       | Write the body to this file instead of returning it                   |

No `Content-Type` is invented for you: set it in `headers` when you send a JSON
body. Four behaviours are worth knowing:

- **Downloads.** `save_to` streams the body straight into the file, so a large or
  binary response is written intact rather than mangled by the text path — the
  response text replaces the body with `Saved N bytes to 'path'`.
- **Redirects.** A request that sends no body follows up to five of them. `POST`,
  `PUT`, and `PATCH` cannot be replayed once their body is on the wire, so a
  redirect to one of those comes back as-is for the agent to follow.
- **Failures.** A connection, TLS, or URL failure is a tool error. An HTTP status
  never is — a `404` is an answer, and the status line says so.
- **Limits.** The response text is capped at 32 KB, and `std.http` offers no
  timeout setting, so a server that accepts a connection and then never answers
  hangs the request the way `curl` without `--max-time` does.

### Searching

`grep` searches file contents and `find` finds files and directories by name:

```
you ❯ where is progressLabel defined?
  ⚙ grep {"pattern":"fn progressLabel"}
  ✓ ./src/tools.zig:21:pub fn progressLabel(name: []const u8) ?[]const u8 {
    ./src/tools.zig:1330:        const label = progressLabel(name) orelse return error.TestUnexpectedResult;
```

| Argument      | Required | Description                                                     |
|---------------|----------|-----------------------------------------------------------------|
| `pattern`     | yes      | `grep`: a regular expression. `find`: a glob on the name |
| `path`        | no       | File or directory to search, defaults to `.` |
| `glob`        | no       | `grep` only: search only files whose name matches, e.g. `*.zig` |
| `ignore_case` | no       | `grep` only: match case-insensitively |

Which program runs is decided once, at startup, from `PATH`, and never by the
agent: `grep` uses `rg` where it is installed and the system `grep` otherwise,
`find` uses `fd` where it is installed and the system `find` otherwise. The
arguments mean the same thing on either side, and neither tool accepts free-form
flags — a command line of your own belongs in `shell`.

Four behaviours are worth knowing:

- **No matches.** A search that found nothing is an answer, not a failure: it
  reports `(no matches)`. A search that *failed* — a pattern the program cannot
  parse, a path that does not exist — comes back as an error carrying the
  program's own message.
- **The backends see different trees.** `rg` and `fd` skip what `.gitignore`
  excludes and what is hidden, which the fallbacks do not. All four skip `.git`
  itself, and none of them leaves the `path` it was given.
- **Limits.** A search that returns more than 256 KB is refused rather than cut
  short, and the message says how to narrow it. What does come back is shown up
  to 8 KB, marked `... (truncated)` beyond that.
- **Regex flavour.** `grep`'s pattern is an extended regular expression —
  `+`, `?`, `|` and `()` stand for themselves, as they do in `rg` — so the same
  pattern selects the same lines whichever backend runs it.

### REPL commands

| Command       | Description                      |
|---------------|----------------------------------|
| `/help`       | Show help                        |
| `/clear`      | Clear conversation history       |
| `/new`        | Start a new conversation (same as `/clear`) |
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
  history.zig  — Prompt history: where it is stored, and when it is saved
  provider.zig — Built-in provider presets
  openai.zig   — OpenAI-compatible HTTP client and JSON serialisation
  tools.zig   — Tool implementations (shell, read_file, write_file, list_dir,
                grep, find, http_request)
  agent.zig   — Agent loop: call API → execute tools → repeat → check completion
  menu.zig    — Option parsing, choice menus, and reading the user's answer
  verifier.zig — Completion judge: prompt, turn summary, verdict parsing
build.zig     — Zig build script
```
