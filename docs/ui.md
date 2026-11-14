# Interface

zagent is a terminal program first. What the screen does, and what the keyboard
does, is described here.

## The interactive session

In a terminal, the interactive session takes the whole screen over: the banner
and the conversation scroll above, and the prompt stays on the last row with the
input area growing upward for multi-line text. The alternate screen is used, so
the shell's own scrollback comes back untouched when zagent exits.

```
  ███████╗ █████╗  ██████╗ ███████╗███╗   ██╗████████╗
  ╚══███╔╝██╔══██╗██╔════╝ ██╔════╝████╗  ██║╚══██╔══╝
    ███╔╝ ███████║██║  ███╗█████╗  ██╔██╗ ██║   ██║
   ███╔╝  ██╔══██║██║   ██║██╔══╝  ██║╚██╗██║   ██║
  ███████╗██║  ██║╚██████╔╝███████╗██║ ╚████║   ██║
  ╚══════╝╚═╝  ╚═╝ ╚═════╝ ╚══════╝╚═╝  ╚═══╝   ╚═╝
  ✦ an AI agent in your terminal

  Model  gpt-4o-mini · openai
  Enter to send, Alt+Enter or Ctrl+J for newline, Ctrl+Z to suspend, Ctrl+D to exit. /help for commands.

❯ list all .zig files in the current directory
  ⚙ bash find . -name '*.zig' -type f
  ✓ exit 0
    ./src/agent/mod.zig
    ./src/model/config.zig
    ./src/tools/bash.zig
    ...

  Assistant
  Here are all the .zig files in the current directory:

  • src/agent/mod.zig — the loop, and the hooks a tool call runs through
  • src/model/config.zig — provider and model settings

  Worked for 3.4s · in 8120 (cached 0) · out 421 · total 8541 tokens · usage 2/2 calls
  ✓ Turn finished
```

Everything the conversation shows starts two columns in. The call's `⚙` sits at
that margin, and the line under it is the status — `✓` or `✗`, then how the
call ended when the result says so: `✓ exit 0`, `✗ exit 42`, `✗ timed out`,
`✗ SIGTERM`. So every result is read the same way whatever the tool printed:
what a call did is known before any of its text is, and nothing the tool said
shares that line. The result itself begins on the line after the status, laid
out where that line's text starts, and the answer's header and body take the
same margin — so a paragraph, a list, a fence and a table all hang off the same
left edge. The prompt's `❯` is the one thing at column zero: it is the left
anchor the rest is read against. A command's listing (`/help`, `/memory`,
`/plan`, `/mcp`) is written at the margin too.

The margin is applied as the text is produced, not as it is drawn, so it is a
terminal's layout only: what a pipe or a file receives is untouched.

A call is one line: the tool's name, then its arguments named rather than
serialised — `⚙ read src/agent/mod.zig · offset 40 · limit 200`, not the JSON
they arrived as. The name is drawn bold and the arguments dim, so a turn is
scanned by what ran rather than by what it was given. The first argument stands
bare because it is what the call is about; the ones after it carry their names,
so that two values are never read as one; and an argument the call did not send
is not shown at all, because a default is not something it asked for. A tool
whose arguments this program does not know — an MCP server's — names every
argument it was sent the same way. What a call carries as a block rather than as
a value — `edit`, `apply_patch` — is drawn under the name instead: the diff it
makes, in the colours it is read in.

On a terminal the line is cut to the width the tool's name leaves, so one call
stays one line however long the command it runs; what a pipe or a file receives
is the whole summary, since there the line is content rather than layout.

`Ctrl+Z` suspends the session the way it suspends any other foreground program:
the terminal is handed back to the shell first, and `fg` resumes zagent, redraws
the whole conversation and restores the line you were typing. The same works
while an answer is streaming.

`/new` starts another session and puts the screen back the way it looked at
startup: the whole screen is cleared and the wordmark, model and new session ID
are drawn again above an empty conversation. Nothing of the conversation just
left stays visible, so an old answer cannot be read as the new session's
context. That conversation is still on disk — `zagent --resume <old-id>`, named
in the line under the header, brings it back.

When stdout is not a terminal (a pipe or a file), the layout stays inline and
the answer is written straight to stdout, so `zagent "q" > notes.md` is clean:
raw markdown, no margin, nothing for another program to trip over.

## REPL commands

| Command       | Description                      |
|---------------|----------------------------------|
| `/help`       | Show help                        |
| `/clear`      | Clear conversation history       |
| `/new`        | Start a new session on a cleared screen |
| `/session`    | Show the current session ID and resume command |
| `/plan`       | Show the plan; `/plan clear` drops it |
| `/memory`     | List saved memories              |
| `/remember <text>` | Save a note to memory        |
| `/forget <n\|all>` | Remove a saved note, or all of them |
| `/model`      | Show the current model           |
| `/status`     | Show token usage and account quota |
| `/mcp`        | List the MCP servers and their tools |
| `/debug`      | Record every step and write an HTML report; see [Debug tracing](debug.md) |
| `/quit`       | Exit                             |
| `Tab` / `Enter` | Insert the selected candidate   |
| `Ctrl+Z`      | Suspend; resume with `fg`        |
| `Ctrl+D`      | Exit                             |

The prompt supports multiple lines: Enter submits; Alt+Enter or Ctrl+J inserts
a newline, and the input area grows upward while the conversation moves up.
In terminals supporting bracketed paste, pasted newlines stay in the editor
until you press Enter to send. Multiline entries can be recalled during the
current session but are omitted from the on-disk input history.

## Prompt history

↑ and ↓ walk back and forward through the prompts of this session and earlier
ones. The history is read at startup and rewritten after every accepted prompt,
from:

- `$XDG_STATE_HOME/zagent/history` (if `XDG_STATE_HOME` is set)
- `~/.local/state/zagent/history` (fallback)

It holds the last 100 entries, and is created with mode `0600`: a prompt can
contain anything you were willing to type at it. Entries longer than 4 KB are
still recalled in the session that typed them, but are not written, so one
pasted blob cannot push everything else out of the file. Lines piped in on stdin
are not history and are never stored, and if the file cannot be written the
session carries on without it.

## Completion popups

Typing `/` at the start of the prompt opens system command candidates. Typing
`@` at a word boundary searches project file paths, and `$` shows a reserved
"Coming soon" entry. Candidates filter as you type. Use ↑/↓ to select, Tab or
Enter to insert, and Esc to dismiss; press Enter again to submit the line.

File search ranks paths with the [fzy](https://github.com/jhawthorn/fzy)
scoring algorithm: a query is a subsequence of the path, so `@sz` finds
`src/zagent.zig`, and matches at a path separator, word boundary or after a dot
score highest while inner gaps cost least. The 100 best matches across the whole
walk are kept, so a good match late in the tree still appears. Search skips
`.git`, build caches and `node_modules`, and bounds traversal to keep large
workspaces responsive. File selection inserts an `@path` reference (paths with
spaces are quoted); it does not attach file contents automatically. These popups
apply only to the REPL prompt.

## Steering a running task

The prompt stays live while a task runs. What you type there is not queued
behind the task: it is handed to the running task and sent to the model with
its next request, so you can redirect the work in progress instead of waiting
for it to finish and asking again. A reply that is already streaming is not cut
short — the guidance lands with the request after it. Read-only commands
(`/help`, `/model`, `/status`, `/mcp`, `/session`) still run immediately, and so
does `/debug`, which starts recording from the next step; the ones that change
session state wait for the task to end.

Press **Esc** to interrupt the current task, terminate its running tools, and
discard input typed while it ran, keeping your own draft. If a completion popup
is open, Esc only closes the popup. A question is no exception to the stop: Esc
at the questions cancels them and ends the run with them, and the answers given
are not sent — inside a free-text row Esc only steps back to that question's
options. Completed actions are not undone.

## Choices

When a request is ambiguous — several reasonable approaches, unclear scope, a
decision only you can make — the agent calls `ask_user` and you get a form:

```
   · 1   · Confirm
  Which approach should I use?
    > 1) Rewrite in place (recommended)  Keeps the history intact.
      2) New file  Leaves the original alone.
      3) Other / 自定义回答
  Tab/Shift+Tab · ↑/↓ select · Enter confirm · Esc cancel
```

Use ↑/↓ (or j/k) to move within a question, then Enter to confirm. The
recommended option is selected initially, or the first option if none is
recommended. Number keys 1–9 select an option directly. Choose Other to type your
own answer; Esc there goes back to the option list, so a mistyped start costs
nothing.

The strip above the question names its tabs: a number per question and a final
**Confirm**. The tab with the keyboard is cyan and underlined, `✓` marks an
answered question, and the confirmation stays a `·` until every one of them has
an answer: it is drawn from the start, but it cannot be walked to while a
question is still open, because there is nothing to submit yet and the way to
answer in your own words is that question's Other row. The last answer moves the
keyboard there instead of sending it off:

```
   ✓ 1   ✓ Confirm
  Confirm
    > 1) Submit  Send the answers as they stand
      2) Supplement  Type your own words to add
  Tab/Shift+Tab · ↑/↓ select · Enter submit · Esc cancel
```

**Submit** sends the answers as they are; **Supplement** asks for a line of your
own words, which is sent with them, so a decision can carry the detail the
options left out. Esc in that line goes back to the confirmation.

Tab and Shift+Tab move between the tabs and wrap around, so an earlier answer can
be revised: answered questions show what they were answered with, and only the
one with the keyboard shows its option rows, which keeps a long form on screen.
Once every question has an answer the confirmation joins that ring, and Tab from
it leads back to the first question.
The form's own words — `Confirm`, `Submit`, `Supplement` — are English; the
questions and their options are whatever the model wrote.

Esc at the tabs cancels the questions and stops the task with them, as it does at
the prompt: nothing is answered, and the agent is not told to decide on its own.
Ctrl+D instead dismisses the form, and the agent carries on from there on its
own. Ctrl+C is deliberately not a way out, because it is pressed by habit. In the
fullscreen session the form takes the rows the prompt had, so nothing typed at a
form reaches the input box or steers the task: the keyboard belongs to the
questions until they are answered.

With no terminal to type at (piped input, or an unsupported terminal) the
recommended option is taken and the agent says so. Interactive menus also work in
single-query mode and render on stderr.

## Thinking

While the model reasons, what it is thinking scrolls in a panel of its own: one
row between the status line and the prompt, dim, always showing the newest text
and letting the row before it go as more arrives. The panel is a window, not a
record — nothing of it joins the conversation. It stays for about three seconds
of the answer, so the thought that led there can still be read, and then closes,
leaving one line behind:

```
  ⠋ thinking… 4s · in 8120 · out 0
  Both of them end in .zig, and the question says list, not read.

  Assistant
  Both files are there: alpha.zig and beta.zig.
  ✻ Thought for 4.2s
```

A turn that ends inside those three seconds closes the panel when it does, so
the line lands at the end of the answer rather than later, and a tool call or an
error closes it at once, because neither belongs under reasoning that has
already finished. Stopping the work with Esc closes it too.

The reasoning is shown when the backend streams it. DeepSeek narrates its own
chains of thought, and the OpenAI API and Codex backend are asked for a
reasoning summary (`reasoning.summary: "auto"`) whenever a reasoning effort is
configured. Nothing is asked for when no effort is set, so a model that does not
reason is never sent a member it would reject, and a provider that narrates
nothing simply opens no panel.

The panel needs the full-screen layout, so a single query, a pipe or a
`TERM=dumb` run shows no reasoning: there is nowhere to scroll it, and the
output belongs to whatever is reading it. A sub-agent's thinking is its own
business and is never shown.

## Live progress

Waiting for the model, and running a tool, each get one animated line
(`⠋ bash… 8s`) with the time so far, so a long wait never looks like a hang. A
[sub-agent](subagents.md#on-the-terminal)'s wait is marked as one, in cyan and
named, and its self-checks are printed under the line it gives back for them.
Live progress is off unless both stdout and stderr are a terminal, where the
line can be taken and given back.

## Task announcement

The main model calls `announce_task` with a `title` and a `description` of the
goal and approach, without a separate planning request. The description is
displayed to the user; terminal titles use the generated title, never raw input.
Both the submitted title and the entire terminal title stay below 80 Unicode
characters, and a follow-up turn that announces no task of its own keeps the
task already in the title. `/new` starts a session with no task in the title, so
the first task of the new session is announced again. Escape sequences are
filtered, and no title control sequence is sent when stderr is redirected.

## Rendering

Replies are markdown, and in a terminal they are rendered rather than printed as
literal markers: headings, emphasis, inline code and fenced blocks get styling,
lists and quotes get a prefix, and lines that carry a prefix wrap with a hanging
indent so continuation lines never fall back to the left margin. Tables are laid
out in columns, with `:---`, `:---:` and `---:` honoured and cells wrapped inside
their column when the table is wider than the terminal. Plain paragraphs are
left to the terminal's own soft-wrap.

Output that is not a terminal — piped, redirected, or under `TERM=dumb` — gets
the raw markdown instead, so `zagent "..." > notes.md` and `zagent "..." | grep`
see exactly what the model wrote. Rendering is selected automatically from
terminal capabilities; no configuration switch is needed.

## Colours and the wordmark

The startup wordmark uses the terminal theme's standard ANSI cyan, with no
custom RGB colours, 256-colour palette or gradient. Other semantic UI colours
also use the terminal's standard palette and follow its theme. Output is
uncoloured when stdout is not a terminal, `TERM=dumb`, or `NO_COLOR` is
non-empty. When the window is too narrow for the letterforms, a one-line
`✦ zagent` takes their place.

## Copying

Dragging over conversation text requests a clipboard copy. Outside tmux this
uses OSC 52; inside tmux it uses `tmux load-buffer -w -` (tmux 3.2+), which also
updates the tmux buffer and works with `set-clipboard external` and
`allow-passthrough off`. The `tmux` executable must be on PATH.

The terminal must support and permit OSC 52 clipboard writes, including over
SSH. If tmux does not detect that support, configure its `clipboard` terminal
feature for your terminal. The copy notice confirms a request, not an
acknowledgement from the system clipboard; command failures show an error
notice.

Selection itself is drawn by the screen buffer: a drag selects whole rows of
conversation text, and the selection is turned into the text to copy rather than
printing the region again.
