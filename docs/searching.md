# Searching

Four independent tools cover searching: `rg` and `grep` search file contents,
`fd` and `find` find files and directories by name.

```
❯ where is progressLabel defined?
  ⚙ rg fn progressLabel
  ✓
    ./src/tools/progress.zig:11:pub fn progressLabel(name: []const u8) ?[]const u8 {
    ./src/tools/progress.zig:38:        const label = progressLabel(name) orelse return error.TestUnexpectedResult;
```

| Argument      | Required | Description                                                     |
|---------------|----------|-----------------------------------------------------------------|
| `pattern`     | yes      | `rg` / `grep`: a regular expression. `fd` / `find`: a glob on the name |
| `path`        | no       | File, directory, or shell-style path glob to search; defaults to `.` |
| `glob`        | no       | `rg` / `grep` only: search only files whose name matches, e.g. `*.zig` |
| `ignore_case` | no       | `rg` / `grep` only: match case-insensitively |
| `context_lines` | no     | `rg` / `grep`: number of surrounding lines before and after matches (integer >= 0; default 0) |
| `max_matches` | no       | `rg` / `grep`: maximum matching lines **per file**, not globally (integer >= 1; default unlimited); the result limit below still applies |
| `hidden`      | no       | `rg` / `fd`: include hidden paths (default false) |
| `no_ignore`   | no       | `rg` / `fd`: do not skip ignored paths (default false) |

## Registration

Default tool registration is decided once at startup from `PATH`: prefer `rg`
over `grep`, and `fd` over `find`. These are four independent tools: calling
`grep` always runs `grep`, and calling `rg` always runs `rg` (likewise for
`find` and `fd`). Missing programs and execution failures are errors, never
triggers for fallback. None accepts free-form flags — use `bash` for a custom
command line. Search `path` globs expand safely without executing shell code.

## Four behaviours worth knowing

- **No matches.** A search that found nothing is an answer, not a failure: it
  reports `(no matches)`. A search that *failed* — a pattern the program cannot
  parse, a path that does not exist — comes back as an error carrying the
  program's own message.
- **The programs see different trees.** `rg` and `fd` skip ignored and hidden
  paths by default; `hidden` and `no_ignore` can override those defaults.
  `grep` and `find` include hidden and ignored paths, but prune `.git`.
- **Limits.** A search that returns more than 256 KB is refused rather than cut
  short, and the message says how to narrow it. What does come back arrives in
  one page that stops short of the result limit and says it did, so a narrower
  pattern, path or glob is what reaches the rest; a single result longer than
  the page is reported instead of being cut. `ls` caps its listing the same way,
  honouring `limit`.
- **Regex flavour.** `grep`'s pattern is an extended regular expression —
  `+`, `?`, `|` and `()` are operators, as they are in `rg`. More advanced
  regex syntax can differ between the two programs.

See also [Tools](tools.md) for the 8 KiB cache threshold and `read` paging.
