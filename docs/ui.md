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
  ⚙ bash {"command":"find . -name '*.zig' -type f"}
  ✓ ./src/agent/mod.zig
./src/model/config.zig
...

Assistant
Here are all the .zig files in the current directory: ...

  ✓ Turn finished
```

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
the answer is written straight to stdout, so `zagent "q" > notes.md` is clean.

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
is open, Esc only closes the popup, and if a question is open, Esc only steps
back through it — out of the free-text row to its options, and out of the menu
to a dismissal — and the task carries on. Completed actions are not undone.

## Choices

When a request is ambiguous — several reasonable approaches, unclear scope, a
decision only you can make — the agent calls `ask_user` and you get a menu:

```
  Which approach should I use?
    > 1) Rewrite in place (recommended)  Keeps the history intact.
      2) New file  Leaves the original alone.
      3) Other / 自定义回答
  ↑/↓ select · Enter confirm · Esc cancel
```

Use ↑/↓ (or j/k) to move within a question, then Enter to confirm. The
recommended option is selected initially, or the first option if none is
recommended. Number keys 1–9 also move the selection. Choose Other to type your
own answer; Esc there goes back to the option list, so a mistyped start costs
nothing. Ctrl+D or Esc at the list dismisses the question and the agent carries
on from there on its own; Ctrl+C is deliberately not a way out, because it is
pressed by habit. Esc stops the task at the prompt, not at a question: backing
out of a question should not throw the run away. In the fullscreen session the
menu takes the rows the prompt had, so nothing typed at a menu reaches the input
box or steers the task: the keyboard belongs to the question until it is
answered.

Several questions asked in one `ask_user` call are drawn as one form, and Tab
and Shift+Tab move between them:

```
  1/3 Which approach should I use?  → Rewrite in place
  2/3 Which tests should I run?  → Full suite
  3/3 Anything else I should know?
    > 1) No
      2) Yes (recommended)
      3) Other / 自定义回答
  Tab/Shift+Tab question · ↑/↓ select · Enter confirm · Esc cancel
```

Enter answers the question that has the keyboard and moves on to the next one
still without an answer; the last answer submits the form. Answered questions
show what they were answered with, and Tab or Shift+Tab reaches them again, so a
wrong answer can be changed until the form is submitted. Only the question with
the keyboard shows its option rows, which keeps a long form on screen. Leaving
the form keeps the answers already given and dismisses the rest.

With no terminal to type at (piped input, or an unsupported terminal) the
recommended option is taken and the agent says so. Interactive menus also work in
single-query mode and render on stderr.

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
