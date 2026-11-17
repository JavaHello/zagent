# Skills

zagent implements the open [Agent Skills](https://agentskills.io) format: a
skill is a folder holding a `SKILL.md` whose frontmatter names it and says what
it is for, followed by the instructions for one kind of task. Scripts,
references and assets can sit beside it in the same folder.

A skill is loaded in three steps, so a machine can hold many of them without
paying for all of them on every request:

| Tier | What the model sees | When |
|------|---------------------|------|
| Catalog | `name` and `description` of every installed skill | At startup, in the system prompt |
| Instructions | The whole `SKILL.md` body, its directory and its file list | When the task matches, through `load_skill` |
| Resources | One bundled file at a time | When the instructions name it, through `read_skill_resource` |

Nothing is executed by installing a skill. Its instructions are guidance for a
task, and the files it bundles are read the way any other file is: a script runs
only when the model calls `bash` on it.

## The file

```
.zagent/skills/pdf-processing/
├── SKILL.md
├── scripts/extract.py
├── references/FORMS.md
└── assets/invoice-template.html
```

```markdown
---
name: pdf-processing
description: Extract text and tables from PDFs and fill their forms. Use when a task mentions PDFs, forms or document extraction.
license: MIT
---

# PDF processing

1. Run `scripts/extract.py <file>` and read what it prints.
2. For forms, read `references/FORMS.md` before editing anything.
```

`name` and `description` are the two fields zagent uses. A skill needs both: a
description is the only thing the model has to decide by, so a skill without one
is skipped and reported. The rest of the spec's frontmatter (`license`,
`compatibility`, `metadata`, `allowed-tools`) is accepted and left out of the
catalog; `allowed-tools` is experimental in the spec and zagent does not act on
it.

`name` must be 1–64 characters of `a-z`, `0-9` and `-`, with no leading,
trailing or doubled hyphen. A skill whose name does not match its directory is
still loaded and reported; one whose name cannot be used at all is skipped.

Frontmatter is read leniently: quoted and plain values, `|` and `>` block
scalars, and a plain value that contains a colon (`description: Use this when:
the user asks about PDFs`) all work, because skills written for other clients
use them.

## Where skills are found

Every directory below is searched in order, and the first skill of a name wins:

| Scope | Directory |
|-------|-----------|
| Extra | Each entry of `AI_SKILLS_DIRS`, colon-separated |
| Project | `<workspace>/.zagent/skills` |
| Project | `<workspace>/.agents/skills` (cross-client convention) |
| User | `~/.zagent/skills` |
| User | `~/.agents/skills` (cross-client convention) |
| User | `~/.claude/skills` (skills installed for another client) |

`AI_SKILLS_DIRS` is read from the environment and takes a leading `~/`:

```sh
AI_SKILLS_DIRS=~/work/skills:/opt/team-skills zagent
```

A missing directory is not a problem. A directory that cannot be read, a
`SKILL.md` larger than 1 MiB, and a name that shadows an earlier one are
reported, not fatal — under the wordmark at startup and in `/skills`.

Project directories are read only after the workspace is trusted, for the reason
[Security and state](security.md#directory-trust-and-global-state) gives: a
skill is instruction text, and a freshly cloned repository must not be able to
put it into the context on its own.

## Activating a skill

The system prompt carries one line per skill:

```text
- Skills are installed procedures: each is a folder whose SKILL.md holds steps…
  When a task matches a skill's description, call **load_skill** with its exact
  name before starting…
  - pdf-processing: Extract text and tables from PDFs… (skill directory: …)
```

When the model calls `load_skill`, the tool result is the instructions without
their frontmatter, wrapped so they are recognisable in the conversation:

```text
<skill_content name="pdf-processing">
# PDF processing

1. Run `scripts/extract.py <file>` …

Skill directory: /home/me/.zagent/skills/pdf-processing
Relative paths in this skill are relative to the skill directory; read a file
the instructions name with read_skill_resource.
Files bundled with this skill:
  assets/invoice-template.html
  references/FORMS.md
  scripts/extract.py
</skill_content>
```

The result is deliberately **not** passed through the
[output cache](tools.md#output-limit): instructions are the procedure the rest
of the turn follows, and a preview plus a `ccr` id would leave the model holding
the beginning of a recipe. A long `SKILL.md` is cut at 64 KiB and points at the
file for the rest, as the spec's "keep it under 500 lines" advice assumes it
will not be.

The two tools exist only when at least one skill is installed; a run that found
none is offered neither, and its prompt says nothing about skills.

## Activating a skill yourself

The user does not have to wait for the model to decide. A `$name` in a task names
an installed skill, and zagent puts that skill's instructions into the request
itself:

```text
❯ $pdf-processing turn this quarter's numbers into a report
```

The model receives the instructions above the request, with a line saying the
user activated them. Typing `$` lists the installed skills with their
descriptions, so the name need not be remembered.

- Only a name the catalog has activates anything: `$HOME`, `$1` and a typo stay
  exactly as typed, and a `$` with no name is plain text.
- A mention works at any word start, in the REPL and in a single query
  (`zagent '$pdf-processing …'`).
- Instructions already in the conversation are not added a second time: a second
  `$name` in the same session, or one after the model loaded the skill itself,
  costs nothing.
- The activation becomes part of the user message, so it is saved with the
  session and replayed with the rest of the conversation.

## Reading a bundled file

`read_skill_resource` takes the skill name and a path relative to the skill
directory. The file must stay inside that directory: `..`, an absolute path and
a symbolic link that resolves outside the skill are all refused, so a skill can
only hand over what it ships.

A file that is not UTF-8 text is refused with the path to read or run it
directly. Up to 64 KiB is handed over; a longer file is cut at a character
boundary and names the path for the rest. Sizes in between are cached by `ccr`
like any other long result, since a bundled reference is data rather than
instructions.

## On the terminal

```
❯ turn this quarter's numbers into a PDF report
  ⚙ load_skill pdf-processing
  ✓
    <skill_content name="pdf-processing">
    …
```

`/skills` lists every directory searched, every skill kept with its description
and `SKILL.md` path, and every problem discovery reported.

## Limits

| Limit | Value |
|-------|-------|
| Skills per run | 100 |
| Entries read per skills directory | 500 |
| `SKILL.md` read | 1 MiB |
| Instructions handed over | 64 KiB, then the file is named |
| Bundled file handed over | 64 KiB, then the file is named |
| Bundled files listed per activation | 40, three directories deep |
| Catalog in the system prompt | 8 KiB, one description capped at 320 bytes |
| Name / description | 64 / 1024 bytes |

A sub-agent works with the same skills as its caller and is offered the same two
tools, because a sub-agent handed a task that matches a skill is in exactly the
position its caller was.
