# Plan

Work that takes more than a few steps is tracked in a checklist of one line per
step, marked as it moves:

```text
Plan 2/5 done. Next: 3. Wire the plan tool
1. [x] Read the tool schemas
2. [x] Write src/plan.zig
   note: compiles
3. [ ] Wire the plan tool
4. [!] Run the integration test
   note: waits for the mock endpoint
```

The model owns the checklist through the `plan` tool, which has three shapes: no
arguments returns the checklist with its progress and the step to take next,
`steps` replaces the whole plan, and `index` with `status` or `note` moves one
step without the rest being rewritten. `[ ]` is pending, `[~]` is the step in
hand, `[x]` is done and `[!]` is blocked; an optional `note:` line under a step
carries why. At most 50 steps of 200 bytes each.

The plan is runtime state of the session, not a file of its own: it lives in
memory while zagent runs and is written into the session snapshot next to the
messages, so `/clear` keeps it, `--resume` brings it back and `/new` starts
without one. The snapshot is saved after each completed tool batch, so a plan
reaches disk with the batch whose call changed it.

The system prompt carries one bullet about the plan: how many steps are done
and which one comes next. It is rebuilt when the plan changes and when history
is cleared, so it always describes the plan rather than the conversation. That
bullet is the point of keeping the plan apart from the messages — the
conversation is a workstation that gets emptied, and the checklist is one of
the few things that survives it.

`/plan` prints the checklist and `/plan clear` empties it.

A [sub-agent](subagents.md) has no plan of its own: the checklist belongs to the
caller, which marks a step done only after verifying the work itself.
