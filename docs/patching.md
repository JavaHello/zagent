# Patching code

`apply_patch` is how the agent changes a file. It takes a Git Unified Diff —
the format `git diff` and `diff -u` write, and the format `git apply` reads —
applies it to the working tree, and prints the change as it goes, in the
terminal's own red and green:

```
❯ rename the greeting in greet.txt to hello
  ⚙ apply_patch
  --- a/greet.txt
  +++ b/greet.txt
  @@ -1,3 +1,3 @@
   alpha
  -beta
  +hello
   gamma
  ✓ Applied 1 file: greet.txt (+1 -1)
```

| Argument | Required | Description                                        |
|----------|----------|----------------------------------------------------|
| `patch`  | yes      | The Git Unified Diff to apply, with its newlines    |

Added lines are green, removed lines are red held back to a faint shade, hunk
headers are cyan and file headers bold. Context lines are left alone, so what
changed is what stands out.

## What a patch may contain

A patch is a header pair (`--- a/path`, `+++ b/path`) and one or more hunks
(`@@ -1,3 +1,3 @@`, then lines marked with a leading space, `-` or `+`). A new
file is sent with `--- /dev/null` and a hunk that adds every line; a deletion
with `+++ /dev/null` and a hunk that removes them. Git's `a/` and `b/` prefixes
are stripped, a name git had to escape is unquoted (`"a/caf\303\251.txt"` is
`café.txt`), hunk counts are recomputed from the lines, and everything else
`git diff` writes around a diff is ignored, so its output applies as it comes.
The outer `*** Begin Patch` / `*** End Patch` markers of a hand-written patch may
be omitted.

The permissions git prints are applied too. `new file mode 100755` creates an
executable, `old mode 100644` with `new mode 100755` above a hunk changes the
permissions as well as the text, and a section that carries those two lines and
nothing else changes only the mode. Git writes no headers at all for an empty
file that is created or deleted, and those sections apply as well.

## Renames

A rename is one of those things `git diff` writes around a diff, and it is
applied as a rename rather than as the pair of headers it looks like:

```
diff --git a/greet.txt b/hello.txt
similarity index 100%
rename from greet.txt
rename to hello.txt
```

That section is the whole change — nothing is read or rewritten, the file
simply has another name, mode and timestamps included (unless the section names
a mode of its own). A rename that changes text as well carries the usual
`---`/`+++` hunks, which are matched against the old file and written under the
new one. The `rename from`/`rename to` lines are the only place a rename is read
from: a patch whose `---` and `+++` name two different files and has them is
refused, because that is also what a mistyped path looks like.

## Six behaviours worth knowing

- **All or nothing.** Every hunk of every file is matched before anything is
  written, so a patch whose third hunk fails leaves the tree exactly as it was.
- **The text decides, not the numbers.** A hunk is applied where the patch says
  it goes, and, when its line numbers are stale, where its context matches — but
  only when that is the one place it matches. Two matches is a coin flip that
  produces a file that compiles and does the wrong thing, so it comes back as an
  error asking for a line of context instead.
- **A mismatch is an error, not a guess.** The agent is told the file, the line,
  the text the patch expected and the text the file has. When a patch is getting
  nowhere, the file has usually changed since it was written: read it again and
  send a fresh patch rather than the same one a second time.
- **Line endings and final newlines are preserved.** A patch that touches one
  line of a CRLF file does not rewrite every other line, and a file that did not
  end with a newline does not gain one unless a line is added at the end.
- **Renames are applied, not inferred.** A git rename section moves the file and
  reports where it came from. Two headers that merely disagree — no `rename
  from`/`rename to` in sight — are an error, and so is a rename onto a file that
  is already there or from one that is not; delete and create in two steps
  instead.
- **What is refused is said to be.** A copy leaves its source in place, which a
  text patch cannot express, and a binary hunk, a symlink or a submodule has no
  lines to apply; each comes back with the section and the reason rather than
  half applied.

A single-file edit can also be made with `write`'s `old_text`/`new_text` form,
see [Tools](tools.md#write).
