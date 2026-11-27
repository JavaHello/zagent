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

Transient network errors (`HttpConnectionClosing`, a reset connection, a broken
pipe, a timeout, an unreachable network, a name lookup no nameserver answered
for) and HTTP 408/429/500/502/503/504 responses are retried, up to three
attempts with a one and then two second pause, each attempt on a fresh
connection. A retry is only sent while no answer text has been shown: once the
reply is streaming onto the screen, a failure ends the turn with its error
rather than printing the answer twice.

A lookup that times out on every nameserver in `/etc/resolv.conf` arrives as
`NameServerFailure`, which is a roaming access point or a network still coming
up rather than a wrong name: the retry resolves it again. A name that does not
exist is `UnknownHostName` and ends the turn as it is.

A request fails at the write as often as at the read: a keep-alive connection
the server or a proxy has dropped is still in the pool, and the next request is
written into a socket that is already gone. The buffered writer only knows how
to say `WriteFailed`, so the reason is read back off the connection itself, and
the failure is treated as the transport failure it is — retried on a fresh
connection, and never left in the pool for the turn after it.

An answer that stops arriving is given up on rather than waited out. A backend
that takes the request, holds the connection open and then sends nothing at all
— a proxy buffering the stream, a queue that never reaches the front — would
otherwise hold the turn for as long as the socket stays up, because the read
waiting for the reply has no deadline of its own. So each request is watched:
when no byte has come back for ten minutes, the connection is shut down and the
turn ends with `the provider sent nothing for ten minutes` instead of waiting.
The limit counts from the last byte, so a long answer that keeps streaming is
never cut short, and a silence is not retried — the next attempt would only
wait the same ten minutes again. Esc still stops the turn at once; the watcher
is not the only way out of a request.

Output that hits the token budget is continued, and eventually reported as
`ResponseTruncated`; the budget and its growth are described in
[Configuration](configuration.md#output-budget-and-truncation).

## Watching a sub-agent

A [sub-agent](subagents.md) runs the same loop on the two clocks its caller
set: every self-check interval it reports its progress on the terminal, and at
its deadline it stops and writes the final report the caller reads. Its tokens
are added to the calling turn.
