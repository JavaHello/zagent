# zagent

[中文使用说明](README.zh-CN.md)

A command-line AI agent built with [Zig](https://ziglang.org/) that can help you with any task using the Responses API.

## Features

- **Interactive REPL** — a full-screen conversation with the prompt pinned to the bottom, and a prompt history that ↑/↓ recall across runs; `Ctrl+Z` suspends and `fg` redraws the whole record
- **Single-query mode** — pass a question directly as a CLI argument
- **Tool use (function calling)** — the agent can execute tools to help you:
  - `bash` — run Bash commands
  - `read` — read a file page by page: `offset` (1-based first line) and `limit` (line count); every returned line is prefixed `<number>:` so a line reference can be read straight off it
  - `write` — create/overwrite with `content`, or replace one exact, unique block with `old_text`/`new_text` (atomic, preserving permissions)
  - `apply_patch` — change files by applying a Git Unified Diff (what `git diff` writes and `git apply` reads), which is then shown to you as a coloured diff
  - `ls` — list directory contents
  - `rg` / `grep` — search file contents; dynamically advertise `rg` if installed on PATH, otherwise `grep`
  - `fd` / `find` — find files by name; dynamically advertise `fd` if installed on PATH, otherwise `find`; prompt guidance follows the selected tools
  - `http` — fetch a URL or call an API, without shelling out to `curl`
  - `ask_user` — put a question to you as an interactive selection menu
- **MCP servers** — start servers described in `mcp.json` and give the tools they offer to the model beside the built-in ones
- **Multi-turn tool chaining** — the agent loops until the task is complete
- **Task announcement from the main model** — the built-in `announce_task` call provides a `title` and `description` of the goal and approach, without a separate planning request. The description is displayed to the user; terminal titles use the generated title, never raw input. Both the submitted title and the entire terminal title stay below 80 Unicode characters.
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

One tool result is held to 40 KiB. `read` pages a file and names the `offset`
the next page starts at; `ls` and the searches stop short of the limit and say
so, so the model narrows the call rather than reading a cut answer as a
complete one; a `bash` command or `http` response that runs past it is cut at
the limit and marked `... (truncated)`; anything else that still lands over it,
an MCP server's answer included, comes back cut at the limit and reported as an
error naming it. No tool description quotes the number: the limit lives in the
code, not in the prompt.

Every run creates one private scratch directory at startup (mode `0700`, a
random name under `$TMPDIR`, or `/tmp` if unset) and names it, together with the
working directory, in the system prompt. The agent is told to use it for complex
or multi-step work and for anything that would change the user's system,
settings or configuration, so the workspace and the host stay untouched; only
the finished deliverable is copied back. Existing tools such as `write`, `read`,
`apply_patch` and `bash` work there, so no separate file API is needed. The
directory is temporary, not durable: it belongs to the process, so agents
started at the same time never share a path and a resumed session gets a fresh
one instead of adopting an old one; `/new` empties it while keeping the path the
system prompt names; and the whole tree, files included, is deleted at exit. The
model may also delete the directory, or whatever it left in it, itself.
Anything worth keeping has to be copied into the workspace or saved with
`remember` before the run ends. The directory is not saved with the session
(`/status` shows the current path). These are ordinary host directories, not
sandboxes or an extra authorization boundary.

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
without creating an empty session. Snapshots must match the current schema;
missing fields and removed fields are rejected rather than migrated.
Session files contain conversation and tool
data: do not commit sensitive snapshots or resume the same ID concurrently.

Snapshots are saved after each completed tool batch and answer. Sessions are
bound to the original working directory. New files use mode 0600 and contain no
API configuration. Invalid or mismatched session files are reported rather than
silently discarded. Interrupted tool batches may have filesystem effects;
inspect the workspace when resuming.

Transient network errors and HTTP 408/429/500/502/503/504 responses are retried up
to three attempts. Exhausted tool iterations, and output still cut off after
bounded continuations, return an error instead of reporting completion.

## Context

A long conversation eventually costs more context than the model has, and a
turn that read half a repository keeps paying for that output long after it
served its purpose. Nothing shrinks the history: there is no compaction step,
no summary request, no automatic token threshold and no way for the model to
drop its own earlier results, because it cannot reliably judge how much of its
context is still needed. `/clear` starts over. The one saving that does happen
is free and mechanical: when the same file region is read again with identical
output, the second result is replaced by a one-line marker that points at the
earlier result instead of repeating it, while both calls and results stay
paired — a Responses request must answer every `function_call` with its
`function_call_output`, and the assistant message replays the exact output
items it was given.

## Memory

zagent keeps durable notes between sessions in the global `memory.md` scoped to the
workspace — a plain markdown list the user can read and edit. A note is saved
when the model calls the `remember` tool at a key point (a preferred convention,
a project fact, a decision that future work must respect), when the user runs
`/remember <text>`. The main model decides what to save; there is no separate
end-of-turn extraction request. Duplicates are ignored, and the list is capped at
200 notes of 500 bytes each.

Saved notes are not injected into the system prompt. The model uses
`memory_search` on demand before relying on past preferences, project conventions,
decisions or workarounds. Local keyword retrieval supports case-insensitive English
and unspaced Chinese (character bigrams), ranks by relevance then recency, and
returns up to 5 notes by default (maximum 10). This is lexical,
not semantic search; retry with shorter keywords or synonyms when needed.
Exact duplicate notes are still ignored on save.
`remember` can add, replace or delete an exact note; `/memory` lists all notes,
and `/forget <n>` or `/forget all` removes them. A read or write failure never
breaks a session.

```sh
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
isolation, API retries, session recovery, input typed into a running task, and
binary replacement during a run.

## Configuration

Configuration can be loaded from a config file and/or environment variables. The config file is read from:

- `$XDG_CONFIG_HOME/zagent` (if `XDG_CONFIG_HOME` is set)
- `~/.config/zagent` (fallback)

The file supports `key=value` lines (comments start with `#`). Supported keys are `AI_PROVIDER`, `AI_URL`, `AI_KEY`, `AI_MODEL`, `AI_MAX_TOKENS`, `AI_MAX_ITERATIONS`, `AI_REASONING_EFFORT`, `AI_SERVICE_TIER`. Environment variables override config file values.

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
| `AI_MEMORY_FILE`   | Global workspace state: `memory.md` | Override where the notes are stored |

Use `AI_` settings in both the config file and environment. An explicit value wins over the provider preset. Provider-specific API keys (`OPENAI_API_KEY`, `DEEPSEEK_API_KEY`) are read from the environment; use `AI_KEY` in the config file.

When a response hits `max_output_tokens`, the main conversation retries the same input with a doubled token budget, up to three retries and a growth cap of 8192 tokens — the most DeepSeek's chat models accept. Since the default budget already equals that cap, the retry only grows a smaller configured `AI_MAX_TOKENS`. Partial tool calls are discarded and completed tool results are retained. If the reply is still cut off, zagent keeps the partial text and asks the model to continue exactly where it stopped, up to eight times; a cut-off tool call is instead re-asked as a request to work in smaller steps, twice. Only when that also fails does the turn end with `ResponseTruncated`, after printing what was produced.

## Rendering

Replies are markdown, and in a terminal they are rendered rather than printed as literal markers: headings, emphasis, inline code and fenced blocks get styling, lists and quotes get a prefix, and lines that carry a prefix wrap with a hanging indent so continuation lines never fall back to the left margin. Tables are laid out in columns, with `:---`, `:---:` and `---:` honoured and cells wrapped inside their column when the table is wider than the terminal. Plain paragraphs are left to the terminal's own soft-wrap.

Output that is not a terminal — piped, redirected, or under `TERM=dumb` — gets the raw markdown instead, so `zagent "..." > notes.md` and `zagent "..." | grep` see exactly what the model wrote. Rendering is selected automatically from terminal capabilities; no configuration switch is needed.

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
  ✓ Task completed
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

### Completion status

The main model judges completion itself. A final answer without tool calls ends
the turn directly (exit code 0), without a status marker, independent checker
request or automatic repair round. The CLI prints `Turn finished` to indicate
that the turn ended, not that the requested work necessarily succeeded.

The model must validate its work before claiming success and explain partial
work, failures, missing permissions/dependencies or required user input in its
answer. Answer text is not parsed as a completion protocol. Transport errors,
truncation and iteration limits still return errors.

### Choices

When a request is ambiguous — several reasonable approaches, unclear scope, a
decision only you can make — the agent calls `ask_user` and you get a menu:

```
  Which approach should I use?
    > 1) Rewrite in place (recommended)  Keeps the history intact.
      2) New file  Leaves the original alone.
      3) Other / 自定义回答
  ↑/↓ select · Enter confirm · Esc cancel
```

Use ↑/↓ (or j/k) to move within a question, then Enter to confirm. The
recommended option is selected initially, or the first option if none is
recommended. Number keys 1–9 also move the selection. Choose Other to type your
own answer; Esc there goes back to the option list, so a mistyped start costs
nothing. Ctrl+D or Esc at the list dismisses the question and the agent carries
on from there on its own; Ctrl+C is deliberately not a way out, because it is
pressed by habit. Esc stops the task at the prompt, not at a question: backing
out of a question should not throw the run away. In the fullscreen session the
menu takes the rows the prompt had, so nothing typed at a menu reaches the input
box or steers the task: the keyboard belongs to the question until it is
answered.

Several questions asked in one message are drawn as one form, and Tab and
Shift+Tab move between them:

```
  1/3 Which approach should I use?  → Rewrite in place
  2/3 Which tests should I run?  → Full suite
  3/3 Anything else I should know?
    > 1) No
      2) Yes (recommended)
      3) Other / 自定义回答
  Tab/Shift+Tab question · ↑/↓ select · Enter confirm · Esc cancel
```

Enter answers the question that has the keyboard and moves on to the next one
still without an answer; the last answer submits the form. Answered questions
show what they were answered with, and Tab or Shift+Tab reaches them again, so a
wrong answer can be changed until the form is submitted. Only the question with
the keyboard shows its option rows, which keeps a long form on screen. Leaving
the form keeps the answers already given and dismisses the rest.

With no terminal to type at (piped input, or an unsupported terminal) the
recommended option is taken and the agent says so. Interactive menus also work in
single-query mode and render on stderr.

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
| `max_matches` | no       | `rg` / `grep`: maximum matching lines **per file**, not globally (integer >= 1; default unlimited); the result limit below still applies |

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
  short, and the message says how to narrow it. What does come back arrives in
  one page that stops short of the result limit and says it did, so a narrower
  pattern, path or glob is what reaches the rest; a single result longer than
  the page is reported instead of being cut. `ls` caps its listing the same way,
  honouring `limit`.
- **Regex flavour.** `grep`'s pattern is an extended regular expression —
  `+`, `?`, `|` and `()` are operators, as they are in `rg`. More advanced
  regex syntax can differ between the two programs.

### Patching code

`apply_patch` is how the agent changes a file. It takes a Git Unified Diff —
the format `git diff` and `diff -u` write, and the format `git apply` reads —
applies it to the working tree, and prints the change as it goes, in the
terminal's own red and green:

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
| `patch`  | yes      | The Git Unified Diff to apply, with its newlines    |

Added lines are green, removed lines are red held back to a faint shade, hunk
headers are cyan and file headers bold. Context lines are left alone, so what
changed is what stands out.

A patch is a header pair (`--- a/path`, `+++ b/path`) and one or more hunks
(`@@ -1,3 +1,3 @@`, then lines marked with a leading space, `-` or `+`). A new
file is sent with `--- /dev/null` and a hunk that adds every line; a deletion
with `+++ /dev/null` and a hunk that removes them. Git's `a/` and `b/` prefixes
are stripped, a name git had to escape is unquoted (`"a/caf\303\251.txt"` is
`café.txt`), hunk counts are recomputed from the lines, and everything else
`git diff` writes around a diff is ignored, so its output applies as it comes.

The permissions git prints are applied too. `new file mode 100755` creates an
executable, `old mode 100644` with `new mode 100755` above a hunk changes the
permissions as well as the text, and a section that carries those two lines and
nothing else changes only the mode. Git writes no headers at all for an empty
file that is created or deleted, and those sections apply as well.

A rename is one of those things `git diff` writes around a diff, and it is
applied as a rename rather than as the pair of headers it looks like:

```
diff --git a/greet.txt b/hello.txt
similarity index 100%
rename from greet.txt
rename to hello.txt
```

That section is the whole change — nothing is read or rewritten, the file
simply has another name, mode and timestamps included (unless the section names
a mode of its own). A rename that changes text as well carries the usual
`---`/`+++` hunks, which are matched against the old file and written under the
new one. The `rename from`/`rename to` lines are the only place a rename is read
from: a patch whose `---` and `+++` name two different files and has them is
refused, because that is also what a mistyped path looks like.

Six behaviours are worth knowing:

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
- **Renames are applied, not inferred.** A git rename section moves the file and
  reports where it came from. Two headers that merely disagree — no `rename
  from`/`rename to` in sight — are an error, and so is a rename onto a file that
  is already there or from one that is not; delete and create in two steps
  instead.
- **What is refused is said to be.** A copy leaves its source in place, which a
  text patch cannot express, and a binary hunk, a symlink or a submodule has no
  lines to apply; each comes back with the section and the reason rather than
  half applied.

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

  ███████╗ █████╗  ██████╗ ███████╗███╗   ██╗████████╗
  ...
  ✦ an AI agent in your terminal
  ✓ mcp: filesystem — 11 tools, 2026-07-28

❯ what is in /tmp?
  ⚙ load_mcp_tools {"server":"filesystem"}
  ✓ Loaded 11 tools from MCP server 'filesystem'.
  ⚙ mcp__filesystem__list_directory {"path":"/tmp"}
  ✓ [FILE] notes.md
    [DIR] projects
```

`⚙ starting` is written while a server is being started; the `✓`/`✗` report is
drawn under the wordmark once the session owns the terminal, so it stays in the
conversation instead of being overwritten by the screen.

`/mcp` lists the servers, their transport, the revision each one settled on,
and what each brought. Seven behaviours are worth knowing:

- **Revisions.** zagent supports only MCP `2026-07-28`: every request carries
  the protocol version and the client's capabilities. Discovery failures and
  older revisions are reported directly; there is no `initialize` handshake
  fallback. `/mcp` shows the revision for connected servers.
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
| `/new`        | Create a new session and empty the scratch directory |
| `/session`    | Show the current session ID and resume command |
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

The prompt stays live while a task runs. What you type there is not queued
behind the task: it is handed to the running task and sent to the model with
its next request, so you can redirect the work in progress instead of waiting
for it to finish and asking again. A reply that is already streaming is not cut
short — the guidance lands with the request after it. Read-only commands
(`/help`, `/model`, `/status`, `/mcp`, `/session`) still run immediately; the
ones that change session state wait for the task to end.

Press **Esc** to interrupt the current task, terminate its running tools, and
discard input typed while it ran, keeping your own draft. If a completion popup
is open, Esc only closes the popup, and if a question is open, Esc only steps
back through it — out of the free-text row to its options, and out of the menu
to a dismissal — and the task carries on. Completed actions are not undone.
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

The main agent uses Responses. There is no
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

The integration target builds the binary and runs the Python 3 suites, covering streamed output, host tool execution, main-model completion statuses, response failures, menus and prompt popups. No isolation backend is required.

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
  compact.zig — Dropping tool results, and deduplicating repeated reads
  memory.zig  — Durable notes: file format, local retrieval, edits
  banner.zig  — The startup wordmark: letterforms, terminal palette, plain-text fallback
  menu.zig    — Option parsing, choice menus, and reading the user's answer
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
