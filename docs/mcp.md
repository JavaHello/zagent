# MCP servers

zagent is an MCP client. Servers described in `mcp.json` are started at
startup and their tools are discovered locally, but their tool descriptions
and parameter schemas are **not** sent to the model up front. Initially the
model sees only a service directory (names and short descriptions) and the
`load_mcp_tools` tool. When a user request needs a service, the model loads it
by name; only that service's tools are added to subsequent model requests.
Loaded services stay available for the lifetime of the process. This is
context lazy loading, not deferred server startup or connection.

Use the optional `description` field to explain when a service is useful.
Without it, the directory falls back to the server's instructions, if any;
directory descriptions are capped at 320 bytes. Full service instructions are
returned when loading. A tool called `read_file` on `filesystem` is offered
as `mcp__filesystem__read_file` after loading.

## The file

`mcp.json` lives next to the config file (`$XDG_CONFIG_HOME/zagent/mcp.json` or
`~/.config/zagent/mcp.json`), and `mcp.example.json` in the repository root
shows every member it takes:

```json
{
  "mcpServers": {
    "filesystem": {
      "description": "Read and browse files under /tmp",
      "command": "npx",
      "args": ["-y", "@modelcontextprotocol/server-filesystem", "/tmp"]
    },
    "linear": {
      "url": "https://mcp.linear.app/mcp",
      "headers": { "Authorization": "Bearer ..." }
    }
  }
}
```

An entry with `command` is started as a subprocess and spoken to over its
standard streams; an entry with `url` is a Streamable HTTP endpoint. `env` adds
or overrides variables in the subprocess's inherited host environment,
`headers` are sent with every HTTP request, `timeoutMs` says how long a request
waits for an answer (default 60000), and `disabled` keeps an entry without
starting it.

## What it looks like

```
  ⚙ mcp: starting "filesystem"…

  ███████╗ █████╗  ██████╗ ███████╗███╗   ██╗████████╗
  ...
  ✦ an AI agent in your terminal
  ✓ mcp: filesystem — 11 tools, 2026-07-28

❯ what is in /tmp?
  ⚙ load_mcp_tools {"server":"filesystem"}
  ✓
    Loaded 11 tools from MCP server 'filesystem'.
  ⚙ mcp__filesystem__list_directory {"path":"/tmp"}
  ✓
    [FILE] notes.md
    [DIR] projects
```

`⚙ starting` is written while a server is being started; the `✓`/`✗` report is
drawn under the wordmark once the session owns the terminal, so it stays in the
conversation instead of being overwritten by the screen.

`/mcp` lists the servers, their transport, the revision each one settled on,
and what each brought.

## Seven behaviours worth knowing

- **Revisions.** zagent supports only MCP `2026-07-28`: every request carries
  the protocol version and the client's capabilities. Discovery failures and
  older revisions are reported directly; there is no `initialize` handshake
  fallback, and no legacy HTTP session ID is kept or replayed. `/mcp` shows the
  revision for connected servers.
- **Naming.** A tool name outside letters, digits, `_` and `-` — or over 64
  characters, which is what an OpenAI-compatible endpoint accepts — is fitted to
  what the endpoint takes; a name that has to be cut keeps a hash of the whole
  thing, so two long tools do not quietly become one. Two tools that would
  still collide are reported, and the second is not offered.
- **Where the file lives.** Only the user-level `mcp.json` is read, never one
  from the directory zagent happens to be running in: a server entry is a
  command, and no repository should get to run one just by being entered.
- **A server that fails is a line, not a funeral.** It is reported on stderr
  with what went wrong, the session carries on with the tools of the servers
  that did start, and every other entry is still read.
- **Timeouts.** A subprocess server is read with a deadline, and a request that
  runs out of time is reported to the model as a failed call. `std.http` has no
  read timeout of its own, so an HTTP server that takes a request and never
  answers holds the agent until it is interrupted. The web tools carry their own
  deadline for exactly this reason, see
  [Web search and fetching](web.md#five-behaviours-worth-knowing); an MCP HTTP
  transport has none.
- **Not implemented.** Servers may ask the client for something mid-call
  (elicitation, sampling, a root list); zagent reports that as a failed call
  saying so. The tool list is also a snapshot from startup: a server that
  changes its tools later is not re-read.
- **Results.** Up to 32 KB of text comes back to the model as the server wrote
  it. Images and audio are named rather than carried — `[image:
  image/png, 48213 bytes]` — because the bytes would cost more of the context
  than they could ever repay, and a result the server marks as an error stays an
  error, so the model can correct itself.

Local servers run directly with the host's environment, permissions and network
access; configured `env` entries add or override variables. See
[Security and state](security.md).
