# Debug tracing

A run that behaves strangely — a tool that never ran, an argument the model
invented, an answer that contradicts its own history — is hard to argue with
from the conversation alone: the terminal shows the result, not what was sent
and what came back. `--debug` records every step of a run, and renders the
record as one HTML page.

```sh
zagent --debug "Reproduce the bug in tests/parser.zig"
zagent --debug --resume <session-id>          # trace a resumed session
AI_DEBUG=1 zagent "..."                        # same, from the environment
```

`AI_DEBUG` is also a config file key, so tracing can be turned on for every run
in a directory; the environment wins over the file, and `--debug` wins over
both. Values `0`, `false`, `off` and `no` mean "no trace".

In an interactive session `/debug` starts recording from that point on, which
is usually what is wanted: the problem has already happened twice before anyone
thinks to look.

```sh
/debug          # record from here, or report where the record is going
```

## Which builds record

Recording is chosen when zagent is built, not only when it runs. A `Debug`
build has the recorder and the report renderer in it; a release build leaves
both out of the binary — no `--debug`, no `/debug`, no `--debug-report` — so a
shipped zagent carries none of this code:

```sh
zig build                                      # Debug: tracing compiled in
zig build -Doptimize=ReleaseFast               # release: no tracing at all
zig build -Doptimize=ReleaseFast -Dtrace       # a release that can still record
zig build -Doptimize=Debug -Dtrace=false       # a Debug build without it
```

In a build without tracing, `--debug`, `AI_DEBUG` and `/debug` each answer with
one line saying the binary cannot record, and the run goes on unrecorded.

## What is recorded

One JSON object per line is appended as the run happens, so a crash, a timeout
or a kill leaves everything up to that point on disk. Each line carries a
sequence number `seq`, milliseconds since the trace opened `t`, wall-clock
milliseconds `at`, the agent it belongs to `agent`, and the request of the turn
`iter`. The steps are:

| `event` | What it holds |
|---------|---------------|
| `run` | Session, model, provider, endpoint, workspace, scratch directory, limits |
| `query` | The task the user asked for |
| `request` | The endpoint, the model and the **complete request body** sent to the API |
| `response` | HTTP outcome, `finish_reason`, token usage, parsed answer text, reasoning, the tool calls asked for, and the **raw response stream** |
| `tool_call` | The tool name, its `call_id` and its arguments |
| `tool_result` | The result text, `is_error`, `exit_code`, `timed_out`, the signal that ended the program when one did (`termination`), the `ccr` entry a preview stands for, and how long it took |
| `failure` | A request that produced no usable reply, with what the server sent |
| `note` | Something the loop did that a request does not explain: a continuation after the output limit, guidance typed mid-task, a stop, a request sent again after a transient failure |
| `turn` | How the turn ended: tool calls made, elapsed time, and whether the model finished |

A [sub-agent's](subagents.md) requests, tool calls and results are written into
the same file, under a name of its own (`subagent s1`, `subagent s2`, …), so the
whole tree is one trace and its steps stay in the order they really happened.

Payloads — request bodies, response streams, tool arguments and results — are
kept up to **128 KiB** each. Past that the opening of the payload is kept and
the step is marked as truncated, because a long history or a large file read
would otherwise grow without bound. Invalid UTF-8 in tool output is replaced
rather than written raw, so every line stays valid JSON.

## Where the files are

Both files are named after the session and the moment the trace was opened, in
the directory's global state folder, beside `sessions/`:

```
debug/<session-id>-<epoch-ms>.jsonl   # the record, one JSON object per line
debug/<session-id>-<epoch-ms>.html    # the report, rendered when the run ends
```

The paths are printed when recording starts and again when the run ends, and
`/debug` prints both while it is recording. Where that folder is, and what
belongs to the workspace: [Security and state](security.md#directory-trust-and-global-state).
Files are mode `0600`. Nothing is uploaded anywhere.

## The report

Open the `.html` file in a browser. It is one self-contained page: no external
stylesheet, no script from the network, no framework, so it can be copied off
the machine it came from and still open.

The page is a vertical flowchart, one node per step, in the order the run took
them — request, response, tool call, tool result, and the next request. Each
node shows the one line that identifies it (the request number, the tool name,
the `finish_reason`, how long it took) and opens onto the bytes behind it:

- the **request body**, pretty-printed, exactly as it went on the wire;
- the **raw response stream**: every `data:` event the server sent, including
  the ones the parser ignored;
- the parsed answer, the reasoning and the tool calls the model asked for;
- the **arguments** of a tool call and the **result** it produced, with its exit
  code and whether it was cut short.

A report can be filtered by kind, searched by text, expanded or collapsed as a
whole. Failure nodes and tool-error nodes are opened by default; everything else
starts closed, so the shape of the run is readable before its contents.

## Rebuilding a report

The report is rendered from the trace file, never from memory, so it can be
rebuilt at any time — after a crash left no page, or on another machine:

```sh
zagent --debug-report /path/to/debug/<session-id>-<epoch-ms>.jsonl
# prints the .html path it wrote beside the trace
```

The trace itself is ordinary JSON lines and is worth reading directly when the
question is narrow:

```sh
jq -r 'select(.event=="tool_call") | "\(.seq) \(.name) \(.args)"' trace.jsonl
jq -r 'select(.event=="response" and .finish=="length") | .seq' trace.jsonl
```

## What to look at first

- A tool that behaved oddly: the `tool_call` node has the arguments the model
  actually sent, which is often not what the answer claimed.
- An answer that ignored its history: the `request` body is the exact input the
  model was given; compare its `input` array with what the conversation shows.
- A reply that ended too early: the `response` node's `finish_reason`, and the
  `raw` stream for a `response.incomplete` or `response.failed` event.
- A turn that looped: the `note` nodes are the continuations, the steering and
  the stops, in the order the loop took them; `turn` says how it ended.

## Cost and privacy

Tracing does not change what is sent to the API: the request body is built the
same way and recorded as it is written. It costs one extra token estimate per
request, and the disk space of the payloads.

The trace holds the system prompt, the conversation, tool output and whatever
those tools read — file contents, command output, HTTP responses. Treat it as
you would treat the session snapshot, only more so: keep it out of a repository
and out of anything shared, and delete the `debug/` folder once the problem is
understood.
