//! Built-in host and session tools, one file per tool.
//! Session tools use Context.agent to access the owning agent's state; their
//! specs, schemas and dispatch share the same registry as host tools.
//!
//! Each tool keeps its implementation, its arguments and its tests together —
//! `bash.zig`, `read.zig`, `write.zig`, `edit.zig`, `apply_patch.zig`, `ls.zig`, `rg.zig`, `grep.zig`,
//! `fd.zig`, `find.zig`, `web_fetch.zig`, `web_search.zig` — over a small shared floor: `result.zig`
//! for the shape of a result, `progress.zig` for the progress labels,
//! `args.zig` for reading a call's JSON arguments, `search.zig` for what the
//! four search tools have in common, `web.zig` for the one HTTP client both web
//! tools ask through, `html.zig` for reading a page as text, and `util.zig` for
//! a handful of helpers.
//! `ccr.zig` is the cache a tool's output is kept in when it is too long for one
//! result, and the `ccr_retrieve` tool that reads it back.
//!
//! `tool.zig` says what a built-in tool is — its name, description, argument
//! schema, progress label and the `run` that parses its arguments and does the
//! work — and `dispatch.zig` lists the specs to send a call to one of them.
//!
//! This file re-exports them, so the rest of the program goes on speaking of
//! `tools.readFilePage` or `tools.execute`. Re-exporting a file is also what
//! puts its tests in the build: nothing else imports these modules.
const result_mod = @import("result.zig");
const tool_mod = @import("tool.zig");
const progress = @import("progress.zig");
const dispatch = @import("dispatch.zig");
const read = @import("read.zig");
const write = @import("write.zig");
const search = @import("search.zig");
const grep_mod = @import("grep.zig");
const rg_mod = @import("rg.zig");
const fd_mod = @import("fd.zig");
const ccr = @import("ccr.zig");

/// What a built-in tool is, and what one is given besides its arguments.
pub const Tool = tool_mod.Tool;
pub const Context = tool_mod.Context;

/// Send one call to the built-in tool that answers it.
pub const execute = dispatch.execute;

// The shape of a tool result, and the sizes the cache keeps it to.
pub const ToolResult = result_mod.ToolResult;
pub const max_output_bytes = ccr.max_output_bytes;
pub const formatToolOutput = result_mod.formatToolOutput;
/// What every tool answers when it has nothing to show.
pub const no_output = result_mod.no_output;

// What the terminal shows while a tool runs.
pub const progressLabel = progress.progressLabel;

// read
pub const readFilePage = read.readFilePage;

// write
pub const writeFile = write.writeFile;

// ccr: the cached output of a command that printed more than one result holds.
pub const ccrDirPath = ccr.dirPath;

// The two search families: their arguments, the backends this machine has, and
// the tool files that build one program's argv and run it.
pub const SearchBackends = search.SearchBackends;
pub const detectSearchBackends = search.detectSearchBackends;
pub const GrepArgs = search.GrepArgs;
pub const parseGrepArgs = search.parseGrepArgs;
pub const FindArgs = search.FindArgs;
pub const parseFindArgs = search.parseFindArgs;
pub const freeGrepArgv = search.freeGrepArgv;

pub const grep = grep_mod.grep;
pub const rgArgv = rg_mod.rgArgv;
pub const rg = rg_mod.rg;
pub const fd = fd_mod.fd;

// web: the client both web tools ask through.
pub const WebConfig = tool_mod.Web;

test {
    _ = @import("schema.zig");
}
