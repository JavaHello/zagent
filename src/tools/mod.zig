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
const std = @import("std");

const result_mod = @import("result.zig");
const tool_mod = @import("tool.zig");
const progress = @import("progress.zig");
const dispatch = @import("dispatch.zig");
const bash = @import("bash.zig");
const read = @import("read.zig");
const write = @import("write.zig");
const apply_patch = @import("apply_patch.zig");
const ls = @import("ls.zig");
const search = @import("search.zig");
const grep_mod = @import("grep.zig");
const rg_mod = @import("rg.zig");
const find_mod = @import("find.zig");
const fd_mod = @import("fd.zig");
const web = @import("web.zig");
const html = @import("html.zig");
const web_fetch = @import("web_fetch.zig");
const web_search = @import("web_search.zig");
const ccr = @import("ccr.zig");

/// What a built-in tool is, and what one is given besides its arguments.
pub const Tool = tool_mod.Tool;
pub const Context = tool_mod.Context;
pub const Hooks = tool_mod.Hooks;

/// Send one call to the built-in tool that answers it.
pub const execute = dispatch.execute;

// The shape of a tool result, and the sizes the cache keeps it to.
pub const ToolResult = result_mod.ToolResult;
pub const max_output_bytes = ccr.max_output_bytes;
pub const page_room_bytes = ccr.page_room_bytes;
pub const formatToolOutput = result_mod.formatToolOutput;
/// What every tool answers when it has nothing to show.
pub const no_output = result_mod.no_output;

// What the terminal shows while a tool runs.
pub const progressLabel = progress.progressLabel;

// bash
pub const executeShell = bash.executeShell;
pub const executeShellWithEnv = bash.executeShellWithEnv;

// read
pub const ReadPage = read.ReadPage;
pub const parseReadPage = read.parseReadPage;
pub const readFile = read.readFile;
pub const readFilePage = read.readFilePage;

// write
pub const writeFile = write.writeFile;
pub const editFile = @import("edit.zig").editFile;

// apply_patch
pub const applyPatch = apply_patch.applyPatch;

// ls
pub const Page = ls.Page;
pub const listDirPage = ls.listDirPage;

// ccr: the cached output of a command that printed more than one result holds.
pub const ccrDirPath = ccr.dirPath;
pub const ccrSaved = ccr.Saved;

// The two search families: their arguments, the backends this machine has, and
// the tool files that build one program's argv and run it.
pub const SearchBackends = search.SearchBackends;
pub const detectSearchBackends = search.detectSearchBackends;
pub const GrepArgs = search.GrepArgs;
pub const parseGrepArgs = search.parseGrepArgs;
pub const FindArgs = search.FindArgs;
pub const parseFindArgs = search.parseFindArgs;
pub const freeGrepArgv = search.freeGrepArgv;

pub const grepArgv = grep_mod.grepArgv;
pub const grep = grep_mod.grep;
pub const rgArgv = rg_mod.rgArgv;
pub const rg = rg_mod.rg;
pub const findArgv = find_mod.findArgv;
pub const find = find_mod.find;
pub const fdArgv = fd_mod.fdArgv;
pub const fd = fd_mod.fd;

// web: the client both web tools ask through, the page reader it hands a
// document to, and the specs of the two tools themselves.
pub const WebConfig = tool_mod.Web;
pub const webRequest = web.get;
pub const webTimeoutSeconds = web.timeout_seconds;
pub const webMaxBodyBytes = web.max_body_bytes;
pub const htmlToText = html.toText;
pub const webFetchSpec = web_fetch.spec;
pub const webSearchSpec = web_search.spec;

test {
    _ = @import("schema.zig");
}
