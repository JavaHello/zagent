# Sub-agents

The `subagent` tool runs one self-contained task in a second agent in the same
process. It shares the working directory, the MCP servers, the tool environment
and the credentials, but not the conversation, the plan, the session or the
terminal: its output is captured and comes back as one report instead of being
printed, its tokens count in the calling turn's totals, and Esc stops both.

It suits a step whose tool output would drown the main conversation — a wide
search, repeated trial runs, one independent block of edits.

## Watching a run

A sub-agent has no deadline of its own: what bounds it
is being watched. The model picks how long it works before a check-in
(`checkin_seconds`, default 300). At that check-in the run pauses, the child is
asked for a progress report through its `report` tool, and the report comes back
as the tool result. The model then either lets it carry on by calling `subagent`
again with the run's `id`, or stops it with `subagent_stop` and reads its final
report — the stopped child writes that report and does no new work. A check-in
of 0 asks at the next request boundary.

## What the child has

The child gets its own system prompt and its own
[scratch directory](security.md#scratch-directory), and at startup only the task
description and the optional context, so the task has to be self-contained. It
is offered no `ask_user`, `plan`, `announce_task`, `memory_save`, `subagent_stop`
or nesting of its own: both sides of the handshake belong to the caller, and
what the child has is `report`.

The plan therefore stays with the main agent. A sub-agent's report is a report:
the caller inspects the work and runs the verification itself, and only then
marks a plan step done.

## On the terminal

A sub-agent's wait is marked as one: its call line is a cyan `⇢ subagent
<title>`, and its progress line is cyan and names the run (`⠋ subagent · count
the tests… 12s`), so a second agent at work is told apart from the main model
thinking.

The name on those lines is the `title` the caller gave the run — one line of
fewer than 80 characters, the summary of the task — and a call without one falls
back to the task's own opening; a resume or a stop names the run by its `id` and
the title it was started with. The name is model output, so its newlines are
flattened and its escape sequences dropped, and a progress line is always one
line.

## Cost

A sub-agent's token usage is added to the turn that called it, so `/status` and
each turn's closing statistics still report what the whole turn cost.

See also [The agent loop](agent-loop.md) and [Interface](ui.md#live-progress).
