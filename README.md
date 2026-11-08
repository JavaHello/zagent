# zagent

[中文使用说明](README.zh-CN.md)

A command-line AI agent built with [Zig](https://ziglang.org/) that can help you with any task using the Responses API.

## Features

- **Interactive REPL** — conversational chat loop, with a prompt history that ↑/↓ recall across runs
- **Single-query mode** — pass a question directly as a CLI argument
- **Tool use (function calling)** — the agent can execute tools to help you:
  - `shell` — run shell commands
  - `read_file` — read file contents
  - `edit_file` — replace one exact, unique text block atomically while preserving file permissions
  - `apply_patch` — change a file by applying a unified diff, which is then shown to you as a coloured diff
  - `write_file` — create or overwrite a whole file
  - `list_dir` — list directory contents
  - `grep` — search file contents, using `rg` where it is installed
  - `find` — find files by name, using `fd` where it is installed
  - `http_request` — fetch a URL or call an API, without shelling out to `curl`
  - `ask_user` — put a question to you as an interactive selection menu
- **MCP servers** — start servers described in `mcp.json` and give the tools they offer to the model beside the built-in ones
- **Multi-turn tool chaining** — the agent loops until the task is complete
- **Completion check** — after a turn that used tools, an independent judge request decides whether your request is really finished, and sends the agent back to work when it is not
- **Choice menus** — when a request is ambiguous, the agent offers concrete options to choose from instead of guessing, with the one it recommends marked
- **Live progress** — waiting for the model, and running a tool, each get one animated line (`⠋ shell… 8s`) with the time so far, so a long wait never looks like a hang. Off unless both stdout and stderr are a terminal, where the line can be taken and given back
- **Built-in provider presets** — one setting selects `deepseek` or `openai`, autodetected from `OPENAI_API_KEY` / `DEEPSEEK_API_KEY` when unset
- **Responses API** — uses `POST /responses` with typed input/output items, function calling and stateless reasoning replay; works with OpenAI, DeepSeek or another endpoint implementing this protocol
- **ANSI colour output**

## Requirements

- Zig 0.17.x
- Linux with bubblewrap (`bwrap`) and GNU coreutils (`timeout`) for tool execution
- An API key and base URL for a Responses-compatible endpoint

## Build

```bash
zig build
```

The binary is written to `zig-out/bin/zagent`.

## Sandboxed tools

Every built-in filesystem, search, HTTP and shell tool runs in a bubblewrap
sandbox. Local MCP servers use the same boundary. Only the directory from which
you start zagent is mounted writable. System programs and libraries under `/usr`
are read-only; the host home, configuration files, credentials, other workspaces,
processes and sockets are hidden. `/tmp` is private and discarded after each tool
call. Zig compilation caches persist under the workspace’s `.zig-cache/global`.
Symlinks cannot reach files outside the mounted workspace. Commands have a
180-second default limit (`shell.timeout_seconds` accepts 1–3600); background processes do not survive the tool call. If sandbox
startup fails, the tool returns an error without an unsandboxed fallback.

Start zagent in the project directory you want it to work on. Files inside that
workspace are available to tools, including any secrets you put there. Built-in
tools receive a clean environment without your API keys. Local MCP servers get
only the environment entries explicitly declared in their `env` configuration.
Install their dependencies ahead of time inside `/usr` or the workspace.

Tool networking is disabled by default. Set `AI_TOOL_NETWORK=1` to permit network
access for commands, HTTP tools and local MCP servers. This shares the host
network, including localhost services. Model API calls and explicitly configured
remote MCP endpoints use the main process network independently of tool network
access. Each sandbox has its own loopback interface even when networking is off;
run a test server and client in the same shell call for local integration tests.

```sh
cd /path/to/project
AI_PROVIDER=deepseek zagent "Analyze this project and update its documentation"
AI_TOOL_NETWORK=1 zagent "Download the public API documentation and summarize it"
```

## Durable conversations

Set `AI_SESSION_FILE` to save the conversation after each completed tool batch and
answer. Starting zagent with the same file resumes its context. The session is
bound to the original working directory. `/clear` also clears the saved session.
The file contains task content and tool results, and should be stored outside the
tool workspace if tools must not edit it. New files use mode 0600; do not share a
session file between concurrent zagent processes. Invalid or mismatched session
files are reported rather than silently discarded. Interrupted tool batches may
have filesystem effects; inspect the workspace when resuming.

```sh
AI_SESSION_FILE="$HOME/.local/state/zagent/project.json" zagent "Implement the task"
AI_SESSION_FILE="$HOME/.local/state/zagent/project.json" zagent "Continue and verify"
```

Transient network errors and HTTP 408/429/500/502/503/504 responses are retried up
to three attempts. Exhausted tool iterations and truncated model output return
an error instead of reporting completion.

## Validation

```sh
zig build
zig build test
python3 tests/sandbox_integration.py
python3 tests/completion_integration.py
python3 tests/responses_failure_integration.py
```

The integration test uses a local mock model endpoint and the actual binary. It
checks editing/search, host and credential isolation, symlink escapes, network
isolation, API retries, session recovery and binary replacement during a run.

## Configuration

Configuration can be loaded from a config file and/or environment variables. The config file is read from:

- `$XDG_CONFIG_HOME/zagent` (if `XDG_CONFIG_HOME` is set)
- `~/.config/zagent` (fallback)

The file supports `key=value` lines (comments start with `#`). Supported keys are `AI_PROVIDER`, `AI_URL`, `AI_KEY`, `AI_MODEL`, `AI_MAX_TOKENS`, `AI_MAX_ITERATIONS`, `AI_MAX_VERIFICATIONS`, `AI_MARKDOWN` (or their `OPENAI_*` equivalents). Environment variables override config file values.

See `zagent.example.conf` for a complete example config file, and
`mcp.example.json` for the MCP servers zagent can be given.

All configuration is also supported through environment variables:

| Variable           | Default                          | Description                          |
|--------------------|----------------------------------|--------------------------------------|
| `AI_PROVIDER`      | *(autodetected)*                 | Select a built-in preset: `deepseek` or `openai` |
| `OPENAI_API_KEY`   | *(required for OpenAI)*          | Your OpenAI (or compatible) API key  |
| `OPENAI_BASE_URL`  | `https://api.openai.com/v1`      | API base URL                         |
| `OPENAI_MODEL`     | `gpt-4o-mini`                    | Model to use                         |
| `OPENAI_MAX_TOKENS`| `8192`                           | Initial output token budget per response    |
| `OPENAI_MAX_ITERATIONS` | `200`                      | Maximum tool-call loop iterations    |
| `OPENAI_MAX_VERIFICATIONS` | `3`                     | Completion checks per query; `0` disables the check |
| `AI_MARKDOWN`      | `true`                           | Render assistant markdown in a terminal |

Every one of these also has a shorter `AI_`-prefixed spelling that works in both the config file and the environment, so `AI_MODEL` and `OPENAI_MODEL` are interchangeable. An explicit value always wins over a value implied by `AI_PROVIDER`. `AI_MARKDOWN` is the exception: it is not a provider setting and has no `OPENAI_` spelling.

When a response hits `max_output_tokens`, both the main conversation and completion check retry the same input with a doubled token budget, up to three retries and a growth cap of 8192 tokens — the most DeepSeek's chat models accept. Since the default budget already equals that cap, the retry only grows a smaller configured `AI_MAX_TOKENS`. Partial tool calls are discarded and completed tool results are retained. If retries still truncate, split the task into smaller steps or use an endpoint with a larger output limit.

## Rendering

Replies are markdown, and in a terminal they are rendered rather than printed as literal markers: headings, emphasis, inline code and fenced blocks get styling, lists and quotes get a prefix, and lines that carry a prefix wrap with a hanging indent so continuation lines never fall back to the left margin. Tables are laid out in columns, with `:---`, `:---:` and `---:` honoured and cells wrapped inside their column when the table is wider than the terminal. Plain paragraphs are left to the terminal's own soft-wrap.

Output that is not a terminal — piped, redirected, or under `TERM=dumb` — gets the raw markdown instead, so `zagent "..." > notes.md` and `zagent "..." | grep` see exactly what the model wrote. Set `AI_MARKDOWN=0` to turn rendering off in a terminal as well.

## Providers

`AI_PROVIDER` selects a built-in preset that supplies the base URL, the default model, and the name of the environment variable holding the API key:

| Provider   | Base URL                     | Default model    | API key variable   |
|------------|------------------------------|------------------|--------------------|
| `openai`   | `https://api.openai.com/v1`  | `gpt-4o-mini`    | `OPENAI_API_KEY`   |
| `deepseek` | `https://api.deepseek.com`   | `deepseek-flash` | `DEEPSEEK_API_KEY` |

To use some other Responses-compatible endpoint, leave `AI_PROVIDER` unset and set `AI_URL` / `AI_MODEL` yourself.

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
turns the check off. A turn that used no tools is never checked. A reported
blocker, partial implementation or a plan is not a completed task. If the
verification budget runs out while the task remains unfinished, the process
returns `CompletionUnverified`.

Two things worth knowing:

- The check costs one extra request per tool-using turn, and it re-sends a
  summary of that turn rather than the whole history. A turn too long for that
  summary keeps its most recent work — the answer, or the failure that stopped
  it — and omits the beginning, so the judge always sees how the turn ended.
- If the judge request fails or its reply cannot be read, the check is asked
  again while the budget lasts, because such a reply says nothing about the
  work; every attempt spends a check. When no usable verdict can be read, the
  candidate answer remains visible, but the process returns
  `CompletionUnverified`.

### Choices

When a request is ambiguous — several reasonable approaches, unclear scope, a
decision only you can make — the agent calls `ask_user` and you get a menu:

```
  Which approach should I use?
  > 1) Rewrite in place (recommended)  Keeps the history intact.
    2) New file  Leaves the original alone.
    3) Other / 自定义回答
  ↑/↓ select · Enter confirm · Ctrl+C cancel
```

Use ↑/↓ (or j/k and Tab) to move, then Enter to confirm. The recommended option
is selected initially, or the first option if none is recommended. Number keys
1–9 also move the selection. Choose Other to type your own answer; Ctrl+C or
Ctrl+D dismisses the menu. The judge can ask the same way:
when it decides the work is blocked on a decision, it returns the options
itself and you get the same menu. With no terminal to type at (piped input,
or an unsupported terminal) the recommended option is taken and the agent says
so. Interactive menus also work in single-query mode and render on stderr.

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

### Patching code

`apply_patch` is how the agent changes a file. It takes a unified diff — the
format `git diff` and `diff -u` produce — applies it to the working tree, and
prints the change as it goes, in the terminal's own red and green:

```
you ❯ rename the greeting in greet.txt to hello
  ⚙ apply_patch
  --- a/greet.txt
  +++ b/greet.txt
  @@ -1,3 +1,3 @@
   alpha
  -beta
  +hello
   gamma
  ✓ Applied 1 file: greet.txt (+1 -1)
```

| Argument | Required | Description                                        |
|----------|----------|----------------------------------------------------|
| `patch`  | yes      | The unified diff to apply, with its newlines        |

Added lines are green, removed lines are red held back to a faint shade, hunk
headers are cyan and file headers bold. Context lines are left alone, so what
changed is what stands out.

A patch is a header pair (`--- a/path`, `+++ b/path`) and one or more hunks
(`@@ -1,3 +1,3 @@`, then lines marked with a leading space, `-` or `+`). A new
file is sent with `--- /dev/null` and a hunk that adds every line; a deletion
with `+++ /dev/null` and a hunk that removes them. Git's `a/` and `b/` prefixes
are stripped, and everything else `git diff` writes around a diff is ignored, so
its output applies as it comes.

Five behaviours are worth knowing:

- **All or nothing.** Every hunk of every file is matched before anything is
  written, so a patch whose third hunk fails leaves the tree exactly as it was.
- **The text decides, not the numbers.** A hunk is applied where the patch says
  it goes, and, when its line numbers are stale, where its context matches — but
  only when that is the one place it matches. Two matches is a coin flip that
  produces a file that compiles and does the wrong thing, so it comes back as an
  error asking for a line of context instead.
- **A mismatch is an error, not a guess.** The agent is told the file, the line,
  the text the patch expected and the text the file has. When a patch is getting
  nowhere, the file has usually changed since it was written: read it again and
  send a fresh patch rather than the same one a second time.
- **Line endings and final newlines are preserved.** A patch that touches one
  line of a CRLF file does not rewrite every other line, and a file that did not
  end with a newline does not gain one unless a line is added at the end.
- **Renames are refused rather than inferred.** A patch naming two different
  files is an error; delete and create in two steps instead.

### MCP servers

zagent is an MCP client. Servers described in `mcp.json` are started at
startup, their tools are listed, and the model is offered them beside the
built-in ones — a tool called `read_file` on a server called `filesystem` is
offered as `mcp__filesystem__read_file`. The file lives next to the config
file, and `mcp.example.json` shows every member it takes:

```json
{
  "mcpServers": {
    "filesystem": {
      "command": "npx",
      "args": ["-y", "@modelcontextprotocol/server-filesystem", "/tmp"]
    },
    "linear": {
      "url": "https://mcp.linear.app/mcp",
      "headers": { "Authorization": "Bearer ..." }
    }
  }
}
```

An entry with `command` is started as a subprocess and spoken to over its
standard streams; an entry with `url` is a Streamable HTTP endpoint. `env` adds
variables to the subprocess's clean sandbox environment, `headers` are sent with
every HTTP request, `timeoutMs` says how long a request waits for an answer
(default 60000), and `disabled` keeps an entry without starting it.

```
  ⚙ mcp: starting "filesystem"…
  ✓ mcp: filesystem — 11 tools, 2025-06-18

you ❯ what is in /tmp?
  ⚙ mcp__filesystem__list_directory {"path":"/tmp"}
  ✓ [FILE] notes.md
    [DIR] projects
```

`/mcp` lists the servers, their transport, the revision each one settled on,
and what each brought. Seven behaviours are worth knowing:

- **Revisions.** zagent speaks the current MCP revision, `2026-07-28`, in which
  every request carries the protocol version and the client's capabilities and
  nothing is negotiated up front. Servers written for the revision before it
  are opened the old way, with an `initialize` handshake: the client asks the
  current question first, and falls back when the answer is a server that has
  never heard of it. `/mcp` shows which revision each server ended up on.
- **Naming.** A tool name outside letters, digits, `_` and `-` — or over 64
  characters, which is what an OpenAI-compatible endpoint accepts — is fitted to
  what the endpoint takes; a name that has to be cut keeps a hash of the whole
  thing, so two long tools do not quietly become one. Two tools that would
  still collide are reported, and the second is not offered.
- **Where the file lives.** Only the user-level `mcp.json` is read, never one
  from the directory zagent happens to be running in: a server entry is a
  command, and no repository should get to run one just by being entered.
- **A server that fails is a line, not a funeral.** It is reported on stderr
  with what went wrong, the session carries on with the tools of the servers
  that did start, and every other entry is still read.
- **Timeouts.** A subprocess server is read with a deadline, and a request that
  runs out of time is reported to the model as a failed call. `std.http` has no
  read timeout, so an HTTP server that takes a request and never answers holds
  the agent until it is interrupted — the same limitation `http_request` has.
- **Not implemented.** Servers may ask the client for something mid-call
  (elicitation, sampling, a root list); zagent reports that as a failed call
  saying so. The tool list is also a snapshot from startup: a server that
  changes its tools later is not re-read.
- **Results.** Up to 32 KB of text comes back to the model, sanitised the way
  any tool result is. Images and audio are named rather than carried — `[image:
  image/png, 48213 bytes]` — because the bytes would cost more of the context
  than they could ever repay, and a result the server marks as an error stays an
  error, so the model can correct itself.

### REPL commands

| Command       | Description                      |
|---------------|----------------------------------|
| `/help`       | Show help                        |
| `/clear`      | Clear conversation history       |
| `/new`        | Start a new conversation (same as `/clear`) |
| `/model`      | Show the current model           |
| `/mcp`        | List the MCP servers and their tools |
| `/quit`       | Exit                             |
| `Tab` / `Enter` | Insert the selected candidate   |
| `Ctrl+D`      | Exit                             |

Typing `/` at the start of the prompt opens system command candidates. Typing
`@` at a word boundary searches project file paths, and `$` shows a reserved
“Coming soon” entry. Candidates filter as you type. Use ↑/↓ to select, Tab or
Enter to insert, and Esc to dismiss; press Enter again to submit the line.
File search skips `.git`, build caches and `node_modules`, and bounds traversal
to keep large workspaces responsive. File selection inserts an `@path` reference
(paths with spaces are quoted); it does not attach file contents automatically.
These popups apply only to the REPL prompt.

### Using a custom Responses-compatible endpoint

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

zagent calls the selected base URL’s `/responses` endpoint. `AI_MODEL` is sent
unchanged, so provider-specific model names remain under your control. The
client uses `max_output_tokens`, flat function definitions, and typed
`function_call` / `function_call_output` items linked with `call_id`.

Requests set `store: false` and request `reasoning.encrypted_content`. Every
returned output item is retained and replayed, including reasoning and function
item IDs; durable sessions preserve them across restarts. Older sessions are
converted to Responses input messages and call/output pairs. Legacy free-form
`reasoning_content` strings are not sent as a Responses reasoning item.

The main agent and the completion checker both use Responses. There is no
automatic fallback to Chat Completions. `AI_URL` is the API base URL (for
example `https://api.openai.com/v1` or `https://api.deepseek.com`), without the
`/responses` suffix. A Chat Completions-only endpoint must be replaced with a
Responses-compatible endpoint.

Protocol mapping follows the [official Responses migration guide](https://developers.openai.com/api/docs/guides/migrate-to-responses).

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
  tools.zig   — Tool implementations (shell, read_file, write_file,
                apply_patch, list_dir, grep, find, http_request)
  diff.zig    — Unified diffs: reading one, applying one, drawing one
  agent.zig   — Agent loop: call API → execute tools → repeat → check completion
  menu.zig    — Option parsing, choice menus, and reading the user's answer
  verifier.zig — Completion judge: prompt, turn summary, verdict parsing
build.zig     — Zig build script
```
