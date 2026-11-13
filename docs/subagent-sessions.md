# Durable sub-agent runs

A child of a durable session writes an independent, atomic snapshot next to its
parent: `<parent session path>.sN.json`. The snapshot uses the existing version-2
conversation format with an optional `child` record (parent session ID, stable
run ID, title and status). Old version-2 snapshots without this record remain
readable. Credentials and generated system prompts are not stored.

The initial user message retains the task and caller context. Subsequent
messages retain reasoning, tools, tool outcomes and self-check reports
(including report tool arguments). Children checkpoint after receiving a model
tool batch, after each tool result, and at normal conversation boundaries;
completion/failure updates the child status. A self-check report is saved with
the turn it belongs to, so its summary survives a process that ends before the
run does.

Recovery is deliberately lazy: after opening the parent session, calling
`subagent` with its previous `sN` reconstructs the child with a fresh runtime,
system prompt and scratch directory, then explicitly continues the saved
conversation. No task is automatically launched by opening a session. Parent
binding is validated before continuation. Existing child files, even completed
ones, reserve their IDs against reuse. Passing a completed run's ID explicitly
requests a follow-up on its completed history; it does not imply interruption or
restart its original task. Recovery prompts distinguish completed, failed and
interrupted histories. Only a missing snapshot is reported as an unknown ID;
invalid IDs, unreadable/corrupt snapshots and other recovery failures are reported
with their error rather than being called missing.

A saved `running` child loads as `interrupted`. Missing confirmations at the end
of a saved tool batch are converted to error tool results stating that the
outcome is unknown and the tool was **not replayed**. Confirmed results are
retained. The continuation prompt requires inspecting state before retrying side
effects. This cannot determine whether an external operation committed before a
crash, nor prevent the model from explicitly choosing a later retry.

Limitations: there is no child-list UI or eager reconstruction; the caller must
retain the ID from its history. Snapshot replacement uses the existing
rename mechanism, not an fsync durability guarantee. Independent parent/child
snapshots are not one transaction. Children started without a durable parent
remain ephemeral. Old scratch contents are not restored.
