# The agent loop

One turn is a loop, not a single request: the model is asked, its tool calls are
run, the results are sent back, and this repeats until it answers without asking
for a tool. Every turn starts with an [announced task](ui.md#task-announcement)
and, when the work has more than a few steps, a [plan](plan.md).

Nothing caps the number of requests in a turn: the loop ends when the model
answers without asking for a tool. A turn that never gets there goes on until
something interrupts it: Esc at the terminal, or the stop a sub-agent's caller
asks for.

Tools run on the host in this process; the ones that start a program (`bash`,
the searches) carry the deadline, output bound and process-group cleanup
described in [Tools](tools.md) and [Security and state](security.md). Esc stops
the loop and its running tools,
see [Interface](ui.md#steering-a-running-task).

## Completion status

The main model judges completion itself. A final answer without tool calls ends
the turn directly (exit code 0), without a status marker, independent checker
request or automatic repair round. The CLI prints `Turn finished` to indicate
that the turn ended, not that the requested work necessarily succeeded.

The model must validate its work before claiming success and explain partial
work, failures, missing permissions/dependencies or required user input in its
answer. Answer text is not parsed as a completion protocol. Blocked, failed,
waiting-for-input and paused turns each read differently on the screen, and
none of them prints `Task completed`.

Transport errors and truncation still return errors.

## Retries and truncation

Transient network errors and HTTP 408/429/500/502/503/504 responses are retried
up to three attempts. Output that hits the token budget is continued, and
eventually reported as `ResponseTruncated`; the budget and its growth are
described in
[Configuration](configuration.md#output-budget-and-truncation).

## Watching a sub-agent

A [sub-agent](subagents.md) runs the same loop on the two clocks its caller
set: every self-check interval it reports its progress on the terminal, and at
its deadline it stops and writes the final report the caller reads. Its tokens
are added to the calling turn.
