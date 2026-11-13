# Tools

The model works by calling tools. Every built-in tool is offered to it beside
the tools of any loaded [MCP server](mcp.md). The agent loops — call, run,
answer with the result — until the task is done, see
[The agent loop](agent-loop.md).

## The built-in set

| Tool | What it does | Page |
|------|--------------|------|
| `bash` | Run a Bash command | below |
| `read` | Read one numbered page of a file | below |
| `write` | Create or overwrite a whole file | below |
| `edit` | Replace one exact block in a file | below |
| `ls` | List a directory | below |
| `apply_patch` | Apply a Git unified diff | [Patching](patching.md) |
| `rg` / `grep` | Search file contents | [Searching](searching.md) |
| `fd` / `find` | Find files by name | [Searching](searching.md) |
| `http` | Fetch a URL or call an API | [HTTP requests](http.md) |
| `ask_user` | Put one or more questions to you as a menu | [Interface](ui.md#choices) |
| `plan` | Keep the checklist of the work in progress | [Plan](plan.md) |
| `memory_save`, `memory_search` | Save and recall durable notes | [Memory](memory.md) |
| `announce_task` | Name the task on the terminal | [Interface](ui.md#task-announcement) |
| `subagent`, `subagent_stop`, `report` | Hand a task to a second agent | [Sub-agents](subagents.md) |
| `load_mcp_tools` | Load an MCP service's tools on demand | [MCP servers](mcp.md) |

Which search programs are offered is decided once at startup from `PATH`:
`rg` is preferred over `grep`, and `fd` over `find`. The prompt follows the
selection, see [Searching](searching.md).

## `bash`

Runs a command with `bash --noprofile --norc -c`, not `/bin/sh`, in the current
working directory. The command inherits the host environment, permissions and
network access — see [Security and state](security.md).

| Argument | Required | Description |
|----------|----------|-------------|
| `command` | yes | The command line to run |
| `timeout_seconds` | no | Deadline for this call, 1–3600; the default is 180 |

The call returns the merged output and the exit status. A command that runs past
the deadline is terminated with its process group, so a background child does
not outlive the call. Background processes are not kept across calls.

Output larger than 8 KiB (8192 bytes) is cached in the current run's scratch
folder. The result keeps the exit status and up to the last 40 lines / 4 KiB,
then names a cache ID, the total line count and the size in bytes.
Stdout is followed by stderr under a `stderr:` label. Counts refer to this
normalized, combined text, not the exit-status or cache-notice lines. The entry
is written as the output arrives and holds at most 64 MiB, so a command that
prints without end is bounded by the deadline and by that size; past it the rest
is read and counted but not kept, and the result says so.

## `ccr_retrieve`

Read cached output without rerunning the call that produced it.

| Argument | Required | Description |
|----------|----------|-------------|
| `id` | yes | Cache ID a cached result named |
| `query` | no | Literal substring filter, ignoring ASCII case |
| `offset` | no | 1-based first line, or first matching line with `query`; default 1 |
| `limit` | no | Positive number of lines; defaults to the page capacity |

For example, `{"id":"012345abcdef","query":"error","offset":1,"limit":20}`
returns matching lines with their original line numbers. A partial page tells
you the next offset. Cache entries are private to each agent's scratch folder;
`/new` and process exit remove them, and resuming a conversation does not
restore old cache entries. An entry is named after its content, so caching the
same output twice — a command rerun, a page read again — is one file answered
by one ID, and a long task does not fill the folder with copies.

## `read`

Reads one page of a file: `offset` is the 1-based first line and `limit` the
number of lines, and every returned line is prefixed `<number>:` so a line
reference can be read straight off the output.

| Argument | Required | Description |
|----------|----------|-------------|
| `path`   | yes | Path to the file |
| `offset` | no | 1-based number of the first line; defaults to 1 |
| `limit`  | no | Number of lines; defaults to as many as the page holds |

The page holds whole lines only and stops short of the output limit, naming the
`offset` the next page starts at — reading on with that `offset` repeats and
skips nothing. Earlier lines are skipped as a stream, so the back of a file
larger than a megabyte can be read without loading it whole. A single line
longer than the output limit (minified JSON, say) comes back as its beginning,
cut on a UTF-8 boundary, with the suggestion to read the rest with `bash`.

A page already in the conversation is not repeated: a read whose path, page and
output are identical to an earlier one is answered with a one-line marker naming
that earlier result and the SHA-256 of the contents. The marker is never counted
as the earlier result still being there — once it is gone from the context, the
page is read in full again, see [Sessions](sessions.md#context).

## `write`

Creates a file or overwrites its entire contents. For an exact block replacement,
use `edit` instead.

| Argument | Required | Description |
|----------|----------|-------------|
| `path` | yes | The file to write |
| `content` | yes | Entire file contents, for creation or full replacement |

A write is atomic and keeps the file's permissions.

## `edit`

Replaces one exact block in an existing file. The non-empty `old_text` must match
exactly once; no match or multiple matches leaves the file untouched. `new_text`
may be empty to delete the matched block.

| Argument | Required | Description |
|----------|----------|-------------|
| `path` | yes | The file to edit |
| `old_text` | yes | The exact, non-empty block to replace |
| `new_text` | yes | Its replacement |

An edit is atomic and keeps the file's permissions.

## `ls`

Lists a directory. The listing stops short of the output limit and says so
rather than cutting a name in half, and honours `limit`.

| Argument | Required | Description |
|----------|----------|-------------|
| `path`   | no | Directory path; defaults to the current directory |
| `limit`  | no | Most entries to list, 1–1000; defaults to 100 |

## Output limit

A tool result larger than 8 KiB is cached in the current run's scratch folder:
the result keeps the first whole lines up to 4 KiB and then names the cache ID,
the line count and the size in bytes, and `ccr_retrieve` reads the rest back
page by page. This is the same cache `bash` writes to, and an entry is named
after its content, so identical output is kept once however often it is
produced.

- `read` pages a file and names the `offset` the next page starts at, and a page
  stays under the threshold, so reading a cached entry back never caches a page
  of it again.
- `ls` and the searches stop short of the limit and say so, so the model
  narrows the call rather than reading a cut answer as a complete one.
- `bash` starts caching at 8 KiB as the output arrives and returns a tail
  preview plus a cache ID, so output it already holds is not written twice.
- An `http` response, an `apply_patch` summary, an MCP server's answer and
  anything else that large is cached the same way.

No tool description quotes the number: the limit lives in the code, not in the
prompt.

## Result text

Every result is sanitised before it reaches the model or the screen: escape
sequences are dropped and the text stays valid UTF-8. A result the tool marks as
a failure stays an error, so the model can correct itself.
