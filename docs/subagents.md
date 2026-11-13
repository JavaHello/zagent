# Sub-agents

The `subagent` tool runs one self-contained task in a second agent in the same
process. It shares the working directory, the MCP servers, the tool environment
and the credentials, but not the conversation, the plan, the session or the
terminal: its output is captured and comes back as one report instead of being
printed, its tokens count in the calling turn's totals, and Esc stops both.

It suits a step whose tool output would drown the main conversation — a wide
search, repeated trial runs, one independent block of edits.

## Two clocks

A sub-agent is bounded by the two moments the caller names when it hands the
task over, and by nothing else:

- `self_check_seconds` (default 600) — every interval, the child is asked for a
  self-check through its `report` tool. The report is a status line that is
  printed on the terminal for the user and does not reach the caller at all; the
  run carries on by itself. An interval of 0 asks at the child's next request
  boundary.
- `deadline_seconds` (default 3600) — at the deadline the child is told to stop
  working and write its final report: what it changed, what it ran, what is
  verified, and what is left undone. That report is what the tool call returns.
  A few minutes of grace are given for the report itself; a child that misses
  even that is stopped where it stands, and its last words are returned as the
  report with the deadline named as the reason the work ended there.

The model that started the run waits once and reads once. There is no verdict to
give, no run to resume and no mid-run stop to ask for: the call returns when the
child is done or its deadline has passed.

A self-check is not a command to keep going. The child that means to stop — the
task finished, or blocked with nothing further it can do — stops there by not
calling `report`: it answers with its final report instead, the run ends on that
answer, and that answer is what the caller reads. Only Esc ends a run the child
itself would have carried on.

## What the child has

The child gets its own system prompt and its own
[scratch directory](security.md#scratch-directory), and at startup only the task
description and the optional context, so the task has to be self-contained. It
is offered no `ask_user`, `plan`, `announce_task`, `memory_save` or nesting of
its own; what it has that the main agent does not is `report`.

The plan therefore stays with the main agent. A sub-agent's report is a report:
the caller inspects the work and runs the verification itself, and only then
marks a plan step done.

## A saved run

A child of a durable session keeps a session of its own, and `subagent` with its
`id` restores it in a later process and lets it carry on. See
[Durable sub-agent runs](subagent-sessions.md).

## On the terminal

A sub-agent's wait is marked as one: its call line is a cyan `⇢ subagent
<title>`, and its progress line is cyan and names the run (`⠋ subagent · count
the tests… 12s`), so a second agent at work is told apart from the main model
thinking.

Each self-check is printed as it arrives, in cyan, with the run it belongs to
and how long the run has been going:

```
  ⇢ self-check, 10m 0s in · s1 "Split the tree" · carrying on, Esc stops it
two of the four tools are split; nothing verified yet
```

The run carries on by itself, so the line says which way the choice went; Esc,
the same key that stops any other task, is what stops it.

The name on those lines is the `title` the caller gave the run — one line of
fewer than 80 characters, the summary of the task — and a call without one falls
back to the task's own opening; a call that names an existing run by its `id`
shows the title that run was started with. The name and the report are model
output, so newlines are flattened, escape sequences dropped, and each line stays
one line.

## Not cached

A sub-agent's report is never replaced by a `ccr` stand-in: it is the one text
the caller verifies the work from, and a preview plus a cache id would hide
exactly what it needs. Nothing a sub-agent runs on its own side is cached
either, since that transcript never reaches the caller.

## Cost

A sub-agent's token usage is added to the turn that called it, so `/status` and
each turn's closing statistics still report what the whole turn cost.

See also [The agent loop](agent-loop.md) and [Interface](ui.md#live-progress).
