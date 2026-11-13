# Development

## Build

```bash
zig build                                  # Debug build, with debug tracing
zig build -Doptimize=ReleaseFast           # release build, without it
zig build -Doptimize=ReleaseFast -Dtrace   # release build that can still trace
```

The binary is written to `zig-out/bin/zagent`. Zig 0.17.x is required.

Debug tracing is a build option rather than a runtime one, so a release binary
has no recorder and no report renderer in it. `zig build test-integration` uses
the default Debug build, which is why the tracing suite runs there. See
[Debug tracing](debug.md#which-builds-record).

## Tests

```bash
zig build test
zig build test-integration
```

`zig build test` runs the unit tests, which cover the application, the built-in
line editor and the Unicode width tables. `zig build test-integration` builds
the binary and runs the Python 3 suites in `tests/`: streamed output, host tool
execution, main-model completion status, response failures, menus and prompt
popups, steering, sessions, memory, plans and sub-agents. They drive the real
binary against a local mock model endpoint, and cover file editing, patching,
searching, working-directory isolation, symlink escapes, environment isolation,
network isolation, API retries, session recovery, input typed into a running
task, binary replacement during a run, the debug trace and its HTML report, and
the exit status at the execution limit. No isolation backend is required.

A single suite can also be run directly:

```bash
python3 tests/execution_integration.py
python3 tests/completion_integration.py
python3 tests/responses_failure_integration.py
python3 tests/debug_integration.py
```

## Project structure

```
src/
  main.zig       — CLI entry point, REPL loop
  agent/         — The agent loop
    mod.zig      — Call API → execute tools → repeat → check completion
    prompt.zig   — The system prompt, the sub-agent prompt, and their limits
    subagent.zig — What a caller and its sub-agent share: self-checks, deadline
  cli/           — The terminal session around the loop
    commands.zig — Slash commands
    completion.zig — Command and @-path completion
    fzy.zig      — The fuzzy scoring used to rank @-path completion
    history.zig  — Prompt history: where it is stored, and when it is saved
    runtime.zig  — The one thread that owns the terminal; workers only enqueue
  model/         — The model client and its configuration
    openai.zig   — OpenAI-compatible HTTP client and JSON serialisation
    provider.zig — Built-in provider presets
    config.zig   — Configuration loading from the config file and environment
    codex_auth.zig — ChatGPT/Codex device login and token refresh
    status.zig   — Status and quota formatting
  tools/         — The built-in tools, one file per tool
    mod.zig      — Re-exports the tool API the rest of the program uses
    tool.zig     — What a built-in tool is: name, description, schema, label, run
    bash.zig     — bash
    read.zig     — read: one numbered page of a file, a repeat folded into a marker
    write.zig    — write: whole-file writes
    edit.zig     — edit: exact-block replacements
    apply_patch.zig — apply_patch: a Git unified diff
    ls.zig       — ls
    rg.zig       — rg
    grep.zig     — grep
    fd.zig       — fd
    find.zig     — find
    http.zig     — http
    search.zig   — What the four search tools share: backends, arguments, paging
    result.zig   — ToolResult, the output limit, sanitising and truncation
    dispatch.zig — Sending one call to the tool that answers it, statically, in this process
    args.zig     — Reading a call's JSON arguments
    progress.zig — The label shown while a tool runs
    util.zig     — Helpers several tools share
    schema.zig   — The JSON schema of every built-in tool, from the tools' specs
  host/          — Running a program on the host
    exec.zig     — Deadline, bounded output, process-group cleanup
    sysinfo.zig  — What machine this is: OS, kernel, architecture, CPUs, memory
  mcp/           — Model Context Protocol
    mod.zig      — Registry, tool aliases, loading a service's tools on demand
    transport.zig — stdio JSON-RPC transport and framing
  ui/            — Terminal presentation
    screen.zig   — Screen buffer, scrolling, selection and copying
    render.zig   — Markdown rendering
    menu.zig     — Option parsing, choice menus, and reading the user's answer
    spinner.zig  — The animation shown while a request or tool runs
    banner.zig   — The startup wordmark: letterforms, palette, plain-text fallback
    term.zig     — Raw mode, size, cursor and escape sequences
    style.zig    — The SGR codes and styles everything else draws with
    selection.zig — Turning a drag into the text to copy
  diff/          — Unified diffs: reading one, applying one, drawing one (mod.zig)
  debug/         — The record a `--debug` run keeps, and its report
    trace.zig    — One JSON line per step: requests, responses, tool calls, results
    report.zig   — The self-contained HTML flowchart rendered from a trace
  state/         — What outlives a turn
    memory.zig   — Durable notes: file format, local retrieval, edits
    plan.zig     — The session plan: steps, snapshot form, prompt bullet
    session.zig  — Session snapshots
    workspace.zig — Trusted directories and the state directory inside them
    scratch.zig  — The per-run scratch directory
  util/          — Small shared modules
    text.zig     — Text helpers that are about bytes: compile-time repetition
    terminal/    — Everything printed from text this program did not write
      ansi.zig   — Recognising the ANSI/VT sequences a terminal acts on
      sanitize.zig — UTF-8, control bytes and one-line flattening
      normalize.zig — CR redraws, blank-line runs and the line they leave
  editor/        — Line editing, history, popup and raw terminal handling
    linenoise.zig — The editor: read loop, key handling, popups and paste
    state.zig    — One edit in progress: buffer, cursor, rows and popup
    history.zig  — Prompt history: storage format and saving
    term.zig     — Raw mode, key reads and terminal size
    unicode.zig  — Moving by character and word across UTF-8
  unicode_width/ — Terminal character widths and Unicode tables
    wcwidth.zig  — wcwidth, wcswidth and sliceWidth
    manual.zig, table_wide.zig, table_zero.zig — The width tables
build.zig     — Zig build script
```

The line editor lives in `src/editor` and the character-width implementation in
`src/unicode_width`; neither needs a local package dependency.

## Adding a built-in tool

A built-in host tool is one file under `src/tools/`. It declares a
`pub const spec: tool.Tool` — the name the model calls, the description and JSON
schema it is offered, the label the terminal shows while it runs, and the `run`
function that answers a call — and that one declaration is what every other user
of the tool reads:

- `dispatch.zig` lists the spec, and `inline for` over the specs resolves a call
  to its `run` when the program is built, with no lookup at run time;
- `schema.zig` derives the definition the model is offered from the same spec,
  so a tool cannot be advertised without being runnable, or the reverse;
- `progress.zig` takes the label from the same spec.

The tool's `run(ctx, arguments)` parses and validates its own JSON arguments: a
call it cannot use comes back as a `ToolResult` with `is_error` set and a
sentence saying what to fix, rather than as an error. `ctx` carries the `std.Io`,
the allocator, and — for a tool that starts a program or reads cached output —
the environment to hand it and this run's `cache_dir`.

Session tools — memory, the plan, sub-agents, questions to the user, the MCP
loader and `announce_task` — also own their implementations in `src/tools/` and
share the dispatch registry. They access session state through `ctx.agent`;
Agent retains session ownership, supervised-run lifecycles and terminal IO.
Tool-specific argument summaries and dynamic progress labels belong to the
spec's optional `summary` and `progress` callbacks, not name checks in Agent.
Only a connected MCP server's tool is matched by its prefix rather than a
built-in spec, because its name is discovered at runtime.

`read` uses `ctx.agent` for the opposite reason to a session tool: it reads the
conversation already in the history, so a page read a second time is answered
with a marker naming the earlier result instead of a second copy of it. That
rewriting happens in the tool, where the call's arguments and its output are
both in hand; the agent loop appends whatever a tool returns and keeps no
knowledge of which tool could repeat itself.

### Execution hooks

`Tool.hooks` provides tool-local `before` and `after` callbacks;
`Context.hooks` wraps the entire dispatch, including MCP calls. Both use the
`Hooks` type from `tool.zig` and receive the context, name and raw arguments.
`ctx.hook_data` can carry caller-owned state for the duration of the call.
The normal execution order is:

```
context.before → tool.before → run → tool.after → context.after
```

A before callback returns `null` to continue, or an owned `ToolResult` to skip
execution. A before error or short-circuit skips that layer's after callback;
an enclosing after callback still observes the inner outcome. After receives
`anyerror!ToolResult`, allowing it to transform a result or handle a run error.
It takes ownership of result content and must return it, or free it when
replacing the result or returning an error. Hooks are synchronous and dispatch
does not retain caller state.

Agent does its terminal work for a call in these hooks rather than around the
dispatch. The context before hook names the call in the terminal title, writes
its announcement line and starts the animation that owns the line while it
runs; the context after hook gives that line back and then calls
`ccr.afterExecute`, which caches materialized output past 8 KiB (including MCP
output) under an id named after the content's SHA-256, so the same output is
kept once, and returns a 4 KiB preview with that `ccr_retrieve` id. Dispatch itself applies
no size limit, so no cache directory or a cache-write failure leaves the
complete result as it is. Bash keeps its streaming CCR cache so it need not
materialize arbitrarily large output. Because the animation is started
in one hook and stopped in the other, both live on the agent whose terminal it
is, and a call is shown the same way whatever tool answers it — there is no
class of quiet calls the UI skips.

## Documentation

The documentation is this folder, `docs/`, with the entry point in
[`docs/index.md`](index.md); `README.md` is the overview and the quick start.
