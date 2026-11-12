# Memory

zagent keeps durable notes between sessions in the global `memory.md` scoped to
the workspace — a plain markdown list the user can read and edit. A note is
saved when the model calls the `memory_save` tool at a key point (a preferred
convention, a project fact, a decision that future work must respect), or when
the user runs `/remember <text>`. The main model decides what to save; there is
no separate end-of-turn extraction request. Duplicates are ignored, and the list
is capped at 200 notes of 500 bytes each.

## Retrieval

Saved notes are not injected into the system prompt. The model uses
`memory_search` on demand before relying on past preferences, project
conventions, decisions or workarounds. Local keyword retrieval supports
case-insensitive English and unspaced Chinese (character bigrams), ranks by
relevance then recency, and returns up to 5 notes by default (maximum 10). This
is lexical, not semantic search; retry with shorter keywords or synonyms when
needed.

## Editing

`memory_save` can add, replace or delete an exact note; `/memory` lists all notes,
and `/forget <n>` or `/forget all` removes them. A read or write failure never
breaks a session.

## Where it lives

The default memory file sits beside the directory's other state, outside the
project, in the workspace's global folder — see
[Security and state](security.md#directory-trust-and-global-state).
`AI_MEMORY_FILE` explicitly overrides this location:

```sh
AI_MEMORY_FILE=/path/to/notes.md zagent
```

Protect a custom memory file from accidental commits.

A [sub-agent](subagents.md) is offered no `memory_save`: durable notes are the
caller's business.
