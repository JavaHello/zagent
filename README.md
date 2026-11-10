# zagent

[中文使用说明](README.zh-CN.md)

A command-line AI agent built with [Zig](https://ziglang.org/) that can help you with any task using the Responses API.

## Features

- **Interactive REPL** — a full-screen conversation with the prompt pinned to the bottom, and a prompt history that ↑/↓ recall across runs; `Ctrl+Z` suspends and `fg` redraws the whole record
- **Single-query mode** — pass a question directly as a CLI argument
- **Tool use (function calling)** — the agent can execute tools to help you:
  - `bash` — run Bash commands
  - `read` — read file contents or an inclusive line range (`start_line`, `end_line`, 1-based); use narrow ranges for large files (output is limited to about 8192 bytes)
  - `write` — create/overwrite with `content`, or replace one exact, unique block with `old_text`/`new_text` (atomic, preserving permissions)
  - `apply_patch` — change a file by applying a unified diff, which is then shown to you as a coloured diff
  - `ls` — list directory contents
  - `rg` / `grep` — search file contents; dynamically advertise `rg` if installed on PATH, otherwise `grep`
  - `fd` / `find` — find files by name; dynamically advertise `fd` if installed on PATH, otherwise `find`; prompt guidance follows the selected tools
  - `http` — fetch a URL or call an API, without shelling out to `curl`
  - `ask_user` — put a question to you as an interactive selection menu
- **MCP servers** — start servers described in `mcp.json` and give the tools they offer to the model beside the built-in ones
- **Multi-turn tool chaining** — the agent loops until the task is complete
- **Plan before execution** — a tool-free model request first identifies the goal and a brief approach; terminal titles use the generated summary, never the raw input, with the entire title kept below 80 Unicode characters. If planning fails, execution continues with a generic title.
- **Completion check** — after a turn that used tools, an independent judge request decides whether your request is really finished, and sends the agent back to work when it is not
- **Choice menus** — when a request is ambiguous, the agent offers concrete options to choose from instead of guessing, with the one it recommends marked
- **Live progress** — waiting for the model, and running a tool, each get one animated line (`⠋ shell… 8s`) with the time so far, so a long wait never looks like a hang. Off unless both stdout and stderr are a terminal, where the line can be taken and given back
- **Built-in provider presets** — one setting selects `deepseek` or `openai`, autodetected from `OPENAI_API_KEY` / `DEEPSEEK_API_KEY` when unset
- **Responses API** — uses `POST /responses` with typed input/output items, function calling and stateless reasoning replay; works with OpenAI, DeepSeek or another endpoint implementing this protocol
- **ANSI colour output**

## Requirements

- Zig 0.17.x
- An API key and base URL for a Responses-compatible endpoint

## Build

```bash
zig build
```

The binary is written to `zig-out/bin/zagent`.

## Copying text

Drag over conversation text to request a clipboard copy. Outside tmux this
uses OSC 52; inside tmux it uses `tmux load-buffer -w -` (tmux 3.2+), which
also updates the tmux buffer and works with `set-clipboard external` and
`allow-passthrough off`. The `tmux` executable must be on PATH.
The terminal must support and permit OSC 52 clipboard writes, including over
SSH. If tmux does not detect that support, configure its `clipboard` terminal
feature for your terminal. The copy notice confirms a request, not an
acknowledgement from the system clipboard; command failures show an error notice.

## Tool execution policy

All built-in filesystem, search, HTTP and shell tools run directly in the
current working directory. They inherit the host environment (including credentials),
filesystem permissions and network access. Start zagent in the intended project
and only run trusted tasks. Zig compilation caches use `.zig-cache/global`.

There is no sandbox or command safety filter. Tools can modify the host system
with the current user's permissions. Local MCP servers also run directly and
inherit the host environment; configured `env` entries add or override variables.

Tool calls retain a 180-second default limit
(`bash.timeout_seconds` accepts 1–3600), output bounds and process-group cleanup.
Commands use `bash --noprofile --norc -c`, not `/bin/sh`.

```sh
cd /path/to/project
AI_PROVIDER=deepseek zagent "Analyze this project and update its documentation"
zagent "Download the public API documentation and summarize it"
```

## Directory trust and global state

On first use in a directory, zagent asks whether you trust it before loading
workspace data, making API requests or starting MCP servers. Type `yes` in a
terminal to approve; any other response exits. Piped input cannot grant trust.
Later launches in that directory reuse the saved approval. Approve a directory
interactively before using zagent there in scripts or pipelines.

Trust, memory and sessions are stored globally, separated by canonical directory:

```text
$XDG_STATE_HOME/zagent/workspaces/<sha256-of-canonical-path>/
  trusted             # full canonical path, checked when loading approval
  memory.md
  sessions/<id>.json
```

Without `XDG_STATE_HOME`, the base is `~/.local/state`. Symlink aliases share
state; different directories do not. Moving a project gives it a new identity.
Delete its `trusted` file to require approval again. Trust is consent to the
execution policy below, not arbitrary-code isolation. Help, version and `models`
management do not require workspace approval.

Project-local `.zagent/` memory and sessions are not read or migrated.

## Durable conversations

Every launch creates a fresh session ID, saved automatically in the directory's
global state folder as `sessions/<id>.json`. The startup message and `/session`
show the ID and resume command. `/new` creates another ID without overwriting
the previous conversation; `/clear` empties only the current session.
From the original working directory, restore a session with:

```sh
zagent --resume <session-id>
zagent --resume <session-id> "Continue the task"
```

Resume retains the ID and model context. Missing, invalid or corrupt IDs fail
without creating an empty session. Session files contain conversation and tool
data: do not commit sensitive snapshots or resume the same ID concurrently.

Snapshots are saved after each completed tool batch and answer. Sessions are
bound to the original working directory. New files use mode 0600 and contain no
API configuration. Invalid or mismatched session files are reported rather than
silently discarded. Interrupted tool batches may have filesystem effects;
inspect the workspace when resuming.

Transient network errors and HTTP 408/429/500/502/503/504 responses are retried up
to three attempts. Exhausted tool iterations, and output still cut off after
bounded continuations, return an error instead of reporting completion.

## Context compaction

A long conversation eventually costs more context than the model has. zagent
estimates the size of the conversation before every request (and between tool
iterations, where output can grow it fastest). Once it crosses
`AI_COMPACT_THRESHOLD` estimated tokens — 48,000 by default — the older messages
are replaced by one summary and the newest `AI_COMPACT_KEEP` messages (16 by
default) are kept verbatim.

The summary is produced by the model in bounded chunks, each one carrying the
summary so far, so compacting a very large history never needs a single
oversized request. The split always falls on a boundary that keeps each tool
result attached to the assistant call that produced it. If the model cannot
produce a usable summary, the history is left untouched and the turn continues;
losing the conversation is worse than one turn over budget. `/compact` runs the
same operation on demand.

```sh
# Summarize sooner, keeping only the last two turns verbatim
AI_COMPACT_THRESHOLD=20000 AI_COMPACT_KEEP=4 zagent
```

Set `AI_COMPACT_THRESHOLD=0` to disable automatic compaction.

## Memory

zagent keeps durable notes between sessions in the global `memory.md` scoped to the
workspace — a plain markdown list the user can read and edit. A note is saved
when the model calls the `remember` tool at a key point (a preferred convention,
a project fact, a decision that future work must respect), when the user runs
`/remember <text>`, or when the conservative end-of-turn extractor decides that
something durable emerged. Duplicates are ignored, and the list is capped at
200 notes of 500 bytes each.

Saved notes are not injected into the system prompt. The model uses
`memory_search` on demand before relying on past preferences, project conventions,
decisions or workarounds. Local keyword retrieval supports case-insensitive English
and unspaced Chinese (character bigrams), ranks by relevance then recency, and
returns up to 5 notes by default (maximum 10), within 4,000 bytes. This is lexical,
not semantic search; retry with shorter keywords or synonyms when needed. The
end-of-turn extractor receives only notes relevant to the current request rather
than a bulk memory dump. Exact duplicate notes are still ignored on save.
`remember` can add, replace or delete an exact note; `/memory` lists all notes,
and `/forget <n>` or `/forget all` removes them. A read or write failure never
breaks a session.

```sh
AI_MEMORY=0 zagent                 # disable memory entirely
AI_MEMORY_AUTO=0 zagent            # keep the remember tool, skip the per-turn extractor
AI_MEMORY_FILE=/path/to/notes.md zagent
```

The default memory file is stored outside the project, scoped to its canonical
directory. `AI_MEMORY_FILE` explicitly overrides this location; protect custom
memory files from accidental commits.

## Validation

```sh
zig build
zig build test
python3 tests/execution_integration.py
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

The file supports `key=value` lines (comments start with `#`). Supported keys are `AI_PROVIDER`, `AI_URL`, `AI_KEY`, `AI_MODEL`, `AI_MAX_TOKENS`, `AI_MAX_ITERATIONS`, `AI_MAX_VERIFICATIONS`, `AI_MARKDOWN`, `AI_COMPACT_THRESHOLD`, `AI_COMPACT_KEEP`, `AI_MEMORY`, `AI_MEMORY_AUTO`. Environment variables override config file values.

See `zagent.example.conf` for a complete example config file, and
`mcp.example.json` for the MCP servers zagent can be given.

All configuration is also supported through environment variables:

| Variable           | Default                          | Description                          |
|--------------------|----------------------------------|--------------------------------------|
| `AI_PROVIDER`      | *(autodetected)*                 | Select a built-in preset: `deepseek` or `openai` |
| `AI_KEY`          | *(optional)*                    | API key for the selected endpoint |
| `OPENAI_API_KEY`   | *(required for OpenAI)*          | Your OpenAI (or compatible) API key  |
| `AI_URL`  | `https://api.openai.com/v1`      | API base URL                         |
| `AI_MODEL`     | `gpt-4o-mini`                    | Model to use                         |
| `AI_MAX_TOKENS`| `8192`                           | Initial output token budget per response    |
| `AI_MAX_ITERATIONS` | `200`                      | Maximum tool-call loop iterations    |
| `AI_MAX_VERIFICATIONS` | `3`                     | Checks per query, requested by `task_complete`; `0` disables checking |
| `AI_MARKDOWN`      | `true`                           | Render assistant markdown in a terminal |
| `AI_COMPACT_THRESHOLD` | `48000`                      | Estimated tokens before older messages are summarized; `0` disables |
| `AI_COMPACT_KEEP`  | `16`                             | Newest messages kept verbatim across a compaction |
| `AI_MEMORY`        | `true`                           | Keep durable notes in the workspace and expose the `remember` tool |
| `AI_MEMORY_AUTO`   | `true`                           | Ask the model after each turn whether anything should be remembered |
| `AI_MEMORY_FILE`   | Global workspace state: `memory.md` | Override where the notes are stored |

Use `AI_` settings in both the config file and environment. An explicit value wins over the provider preset. Provider-specific API keys (`OPENAI_API_KEY`, `DEEPSEEK_API_KEY`) are read from the environment; use `AI_KEY` in the config file.

When a response hits `max_output_tokens`, both the main conversation and completion check retry the same input with a doubled token budget, up to three retries and a growth cap of 8192 tokens — the most DeepSeek's chat models accept. Since the default budget already equals that cap, the retry only grows a smaller configured `AI_MAX_TOKENS`. Partial tool calls are discarded and completed tool results are retained. If the reply is still cut off, zagent keeps the partial text and asks the model to continue exactly where it stopped, up to eight times; a cut-off tool call is instead re-asked as a request to work in smaller steps, twice. Only when that also fails does the turn end with `ResponseTruncated`, after printing what was produced.

## Rendering

Replies are markdown, and in a terminal they are rendered rather than printed as literal markers: headings, emphasis, inline code and fenced blocks get styling, lists and quotes get a prefix, and lines that carry a prefix wrap with a hanging indent so continuation lines never fall back to the left margin. Tables are laid out in columns, with `:---`, `:---:` and `---:` honoured and cells wrapped inside their column when the table is wider than the terminal. Plain paragraphs are left to the terminal's own soft-wrap.

Output that is not a terminal — piped, redirected, or under `TERM=dumb` — gets the raw markdown instead, so `zagent "..." > notes.md` and `zagent "..." | grep` see exactly what the model wrote. Set `AI_MARKDOWN=0` to turn rendering off in a terminal as well.

The startup wordmark uses the terminal theme's standard ANSI cyan, with no custom RGB colours, 256-colour palette or gradient. Other semantic UI colours also use the terminal's standard palette and follow its theme. Output is uncoloured when stdout is not a terminal, `TERM=dumb`, or `NO_COLOR` is non-empty. When the window is too narrow for the letterforms, a one-line `✦ zagent` takes their place.

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
  ███████╗ █████╗  ██████╗ ███████╗███╗   ██╗████████╗
  ╚══███╔╝██╔══██╗██╔════╝ ██╔════╝████╗  ██║╚══██╔══╝
    ███╔╝ ███████║██║  ███╗█████╗  ██╔██╗ ██║   ██║
   ███╔╝  ██╔══██║██║   ██║██╔══╝  ██║╚██╗██║   ██║
  ███████╗██║  ██║╚██████╔╝███████╗██║ ╚████║   ██║
  ╚══════╝╚═╝  ╚═╝ ╚═════╝ ╚══════╝╚═╝  ╚═══╝   ╚═╝
  ✦ an AI agent in your terminal

  Model  gpt-4o-mini · openai
  Enter to send, Alt+Enter or Ctrl+J for newline, Ctrl+Z to suspend, Ctrl+D to exit. /help for commands.

❯ list all .zig files in the current directory
  ⚙ shell {"command":"find . -name '*.zig' -type f"}
  ✓ ./src/agent.zig
./src/config.zig
...

Assistant
Here are all the .zig files in the current directory: ...

  ⟳ checking completion…
  ✓ completion check passed
```

In a terminal, the interactive session takes the whole screen over: the banner
and the conversation scroll above, and the prompt stays on the last row with
the input area growing upward for multi-line text. The alternate screen is
used, so the shell's own scrollback comes back untouched when zagent exits.

`Ctrl+Z` suspends the session the way it suspends any other foreground program:
the terminal is handed back to the shell first, and `fg` resumes zagent, redraws
the whole conversation and restores the line you were typing. The same works
while an answer is streaming.

When stdout is not a terminal (a pipe or a file), the layout stays inline and
the answer is written straight to stdout, so `zagent "q" > notes.md` is clean.

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

Completion checks are explicitly requested by the AI, not automatically triggered
by tool use. Once the work and validation are finished, the AI calls
`task_complete` and gives its final answer. Only then does zagent send the user's
request plus a summary of the work (tool calls, short tool results, the final
answer) to an independent model request with no tools advertised, and expect

```json
{"complete": false, "reason": "The tests were never run.", "next_step": "Run zig build test."}
```

An unfinished verdict is printed and fed back into the conversation, and the
agent keeps working. Up to `AI_MAX_VERIFICATIONS` checks are made per query
(3 by default); the budget is printed when it runs out, and `AI_MAX_VERIFICATIONS=0`
turns the check off. Without `task_complete`, no judge request is made: tool-using
turns end as `Task paused`, while plain conversation ends normally. Further tool
work after a declaration invalidates it; the AI must declare completion again.
A reported blocker, partial implementation or a plan is not a completed task.
When the checker identifies an unavailable external prerequisite (such as
private Maven dependencies or authentication), the turn ends normally with
`Task blocked`, the reason and the next step. It does not retry, throw
`CompletionUnverified`, or print `Task completed`. This settled blocked state
exits with code 0; it does **not** certify that implementation or tests passed.
Resume with a new query once the prerequisite is available. If the
verification budget runs out while the task remains unfinished, the process
returns `CompletionUnverified`. The final rejection does not start another repair
round with no checks left. It prints the rejection reason, the suggested next
step (when supplied), and a configuration hint. Continue that step in a new
query, or raise `AI_MAX_VERIFICATIONS` before starting a task that needs more
repair rounds; a larger budget alone does not establish completion.

Two things worth knowing:

- Each explicit completion check costs an extra request, and it re-sends a
  summary of that turn rather than the whole history. A turn too long for that
  summary keeps its most recent work — the answer, or the failure that stopped
  it — and omits the beginning, so the judge always sees how the turn ended.
  Long tool results are shortened in the middle rather than at the end: a test
  run's verdict, or a command's last lines, are the evidence the check rules
  on, so they travel with the command that produced them.
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

`http` fetches a URL or calls an API without going through `curl`,
returning the status line, the response headers, and the body:

```
❯ fetch https://httpbin.org/json and tell me the content type
  ⚙ http {"url":"https://httpbin.org/json"}
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
❯ where is progressLabel defined?
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
| `context_lines` | no     | `rg` / `grep`: number of surrounding lines before and after matches (integer >= 0; default 0) |
| `max_matches` | no       | `rg` / `grep`: maximum matching lines **per file**, not globally (integer >= 1; default unlimited); the output byte limit still applies |

Default tool registration is decided once at startup from `PATH`: prefer `rg`
over `grep`, and `fd` over `find`. These are four independent tools: calling
`grep` always runs `grep`, and calling `rg` always runs `rg` (likewise for
`find` and `fd`). Missing programs and execution failures are errors, never
triggers for fallback. None accepts free-form flags — use `bash` for a custom
command line. Search `path` globs expand safely without executing shell code.

Four behaviours are worth knowing:

- **No matches.** A search that found nothing is an answer, not a failure: it
  reports `(no matches)`. A search that *failed* — a pattern the program cannot
  parse, a path that does not exist — comes back as an error carrying the
  program's own message.
- **The programs see different trees.** `rg` and `fd` skip ignored and hidden
  paths by default; `hidden` and `no_ignore` can override those defaults.
  `grep` and `find` include hidden and ignored paths, but prune `.git`.
- **Limits.** A search that returns more than 256 KB is refused rather than cut
  short, and the message says how to narrow it. What does come back is shown up
  to 8 KB, marked `... (truncated)` beyond that.
- **Regex flavour.** `grep`'s pattern is an extended regular expression —
  `+`, `?`, `|` and `()` are operators, as they are in `rg`. More advanced
  regex syntax can differ between the two programs.

### Patching code

`apply_patch` is how the agent changes a file. It takes a unified diff — the
format `git diff` and `diff -u` produce — applies it to the working tree, and
prints the change as it goes, in the terminal's own red and green:

```
❯ rename the greeting in greet.txt to hello
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
startup and their tools are discovered locally, but their tool descriptions
and parameter schemas are **not** sent to the model yet. Initially the model
sees only a service directory (names and short descriptions) and the
`load_mcp_tools` tool. When a user request needs a service, the model loads it
by name; only that service's tools are added to subsequent model requests.
Loaded services stay available for the lifetime of the process. This is
context lazy loading, not deferred server startup or connection.

Use the optional `description` field to explain when a service is useful.
Without it, the directory falls back to the server's instructions, if any;
directory descriptions are capped at 320 bytes. Full service instructions are
returned when loading. A tool called `read_file` on `filesystem` is offered
as `mcp__filesystem__read_file` after loading. The file lives next to the config
file, and `mcp.example.json` shows every member it takes:

```json
{
  "mcpServers": {
    "filesystem": {
      "description": "Read and browse files under /tmp",
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
or overrides variables in the subprocess's inherited host environment, `headers` are sent with
every HTTP request, `timeoutMs` says how long a request waits for an answer
(default 60000), and `disabled` keeps an entry without starting it.

```
  ⚙ mcp: starting "filesystem"…
  ✓ mcp: filesystem — 11 tools, 2025-06-18

❯ what is in /tmp?
  ⚙ load_mcp_tools {"server":"filesystem"}
  ✓ Loaded 11 tools from MCP server 'filesystem'.
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
  the agent until it is interrupted — the same limitation `http` has.
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
| `/new`        | Create a new session, preserving the previous one |
| `/session`    | Show the current session ID and resume command |
| `/compact`    | Summarize older messages to free context |
| `/memory`     | List saved memories              |
| `/remember <text>` | Save a note to memory        |
| `/forget <n\|all>` | Remove a saved note, or all of them |
| `/model`      | Show the current model           |
| `/status`     | Show token usage and account quota |
| `/mcp`        | List the MCP servers and their tools |
| `/quit`       | Exit                             |
| `Tab` / `Enter` | Insert the selected candidate   |
| `Ctrl+Z`      | Suspend; resume with `fg`        |
| `Ctrl+D`      | Exit                             |

The prompt supports multiple lines: Enter submits; Alt+Enter or Ctrl+J inserts
a newline, and the input area grows upward while the conversation moves up.
In terminals supporting bracketed paste, pasted newlines stay in the editor
until you press Enter to send. Multiline entries can be recalled during the
current session but are omitted from the on-disk input history.

Typing `/` at the start of the prompt opens system command candidates. Typing
`@` at a word boundary searches project file paths, and `$` shows a reserved
“Coming soon” entry. Candidates filter as you type. Use ↑/↓ to select, Tab or
Enter to insert, and Esc to dismiss; press Enter again to submit the line.

Press **Esc** to interrupt the current task, terminate its running tools, and clear
queued questions while keeping your input draft. If a completion popup is open,
Esc only closes the popup. Completed actions are not undone.
File search skips `.git`, build caches and `node_modules`, and bounds traversal
to keep large workspaces responsive. File selection inserts an `@path` reference
(paths with spaces are quoted); it does not attach file contents automatically.
These popups apply only to the REPL prompt.

### Using a custom Responses-compatible endpoint

```bash
export AI_URL=https://your-endpoint/v1
export OPENAI_API_KEY=your-key
export AI_MODEL=your-model
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
zig build test-integration
```

The integration target builds the binary and runs the Python 3 suites, covering streamed output, host tool execution, completion checks, response failures, menus and prompt popups. No isolation backend is required.

## Project structure

```
src/
  editor/      — Line editing, history, popup and raw terminal handling
  unicode_width/ — Terminal character widths and Unicode tables
  main.zig     — CLI entry point, REPL loop
  config.zig   — Configuration loading from the config file and environment
  history.zig  — Prompt history: where it is stored, and when it is saved
  provider.zig — Built-in provider presets
  openai.zig   — OpenAI-compatible HTTP client and JSON serialisation
  tools.zig   — Tool implementations (bash, read, write,
                apply_patch, ls, rg/grep, fd/find, http)
  diff.zig    — Unified diffs: reading one, applying one, drawing one
  agent.zig   — Agent loop: call API → execute tools → repeat → check completion
  compact.zig — Context budget, safe cut points, and summary requests
  memory.zig  — Durable notes: file format, prompt section, extraction
  banner.zig  — The startup wordmark: letterforms, terminal palette, plain-text fallback
  menu.zig    — Option parsing, choice menus, and reading the user's answer
  verifier.zig — Completion judge: prompt, turn summary, verdict parsing
build.zig     — Zig build script
```

## ChatGPT / Codex subscription authentication

No Codex CLI installation is needed:

```sh
zagent login
export AI_PROVIDER=codex
zagent models
export AI_MODEL=gpt-5.4  # select a model available to your account
zagent "Inspect this project"
zagent logout
```

Open the official device authorization URL printed by `login` in a browser on any device and enter the displayed code. Device authorization must be enabled for the account. This is an independent implementation of the official Codex protocol, not an OpenAI-published client.

`/status` shows the current model and the last turn's input/output tokens (server usage or local estimates). With `AI_PROVIDER=codex`, it also fetches ChatGPT subscription usage windows, showing used/remaining percentages and reset countdowns. Other providers' account quotas must be checked in their billing dashboards. This command does not make a model request; quota lookup failures do not interrupt the conversation.

ChatGPT credentials use `https://chatgpt.com/backend-api/codex/responses` and `/models`; they are not API keys for `https://api.openai.com/v1`. The existing `openai` provider continues to use separately billed API keys. The `codex` provider rejects custom `AI_URL` values and does not use `AI_KEY` for authentication. `models` prints the server's original JSON.

Tokens are stored separately in `$HOME/.config/zagent/codex-auth.json` with mode `0600`. Access tokens are checked before requests and refreshed near expiration; rotated refresh tokens are saved. Do not share this file or run concurrent logins/refreshes against it. Run `login` again after a refresh failure. `logout` deletes local credentials without revoking the server grant. Existing Codex CLI credentials are untouched.

Codex requests always stream, move system instructions into `instructions`, and omit the unsupported `max_output_tokens` field. Available models and limits depend on the account. Backend compatibility may change with the official client.

References: [official authentication](https://developers.openai.com/codex/auth), [official gateway routing](https://learn.chatgpt.com/docs/enterprise/connect-to-a-gateway?gateway-auth=api-key).
