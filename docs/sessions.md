# Sessions

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

Snapshots are saved after each completed tool batch and answer, so nothing waits
for a clean exit. Sessions are bound to the original working directory. New
files use mode `0600` and contain no API configuration. Invalid or mismatched
session files are reported rather than silently discarded. Interrupted tool
batches may have filesystem effects; inspect the workspace when resuming.

A snapshot carries the conversation, its tool results and the
[plan](plan.md) of the work in progress, so resuming restores all three. Session
files contain conversation and tool data: do not commit sensitive snapshots or
resume the same ID concurrently.

Where the folder is, how trust relates to it, and what the project-local
`.zagent/` folder means: [Security and state](security.md#directory-trust-and-global-state).

## Context

A long conversation eventually costs more context than the model has, and a
turn that read half a repository keeps paying for that output long after it
served its purpose. Nothing shrinks the history: there is no compaction step,
no summary request, no automatic token threshold and no way for the model to
drop its own earlier results, because it cannot reliably judge how much of its
context is still needed. `/clear` starts over.

The one saving that does happen is free and mechanical: when the same file
region is read again with identical output, the second result is replaced by a
one-line marker that points at the earlier result instead of repeating it, while
both calls and results stay paired — a Responses request must answer every
`function_call` with its `function_call_output`, and the assistant message
replays the exact output items it was given.

What must outlive a cleared conversation therefore lives beside the messages
rather than in them: the [plan](plan.md) is kept in memory and saved into the
session snapshot, and the system prompt names it with how far along it is, so
the next request after a `/clear` or a resume picks the work up from the plan
instead of from a history that is no longer there. Durable facts between
sessions go to [memory](memory.md) instead.

## Commands

| Command    | Effect |
|------------|--------|
| `/session` | Show the current session ID and resume command |
| `/new`     | Create a new session and empty the scratch directory |
| `/clear`   | Clear conversation history, keeping the session and the plan |
| `/status`  | Show token usage and account quota |

See [Interface](ui.md#repl-commands) for the full command list.
