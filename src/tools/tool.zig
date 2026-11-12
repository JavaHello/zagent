//! What a built-in tool is.
//!
//! One built-in tool lives in one file, which declares a `spec: Tool` and the
//! `run` function that spec names: the name the model calls, what it is told
//! about the tool, the line the terminal shows while it works, and the code
//! that parses and validates that call's arguments and does what they ask.
//!
//! Nothing else keeps a copy of a tool's name or of what its arguments are:
//! `dispatch.zig` lists the specs to send a call to one of them, `schema.zig`
//! turns the same specs into what the model is offered, and `progress.zig`
//! reads the same label. A tool that owns its arguments is also the only place
//! that can say what went wrong with them, which is why a call it cannot use
//! comes back as a result rather than an error.
const std = @import("std");
const result_mod = @import("result.zig");

pub const ToolResult = result_mod.ToolResult;

/// What a tool is given besides its JSON arguments: IO, allocation, program
/// environment and optional agent state for session tools such as subagent.
pub const Context = struct {
    io: std.Io,
    allocator: std.mem.Allocator,
    /// Session state for tools such as subagent; host-only calls may omit it.
    agent: ?*@import("../agent/mod.zig").Agent = null,
    /// Answers collected together for the questions in this model message.
    answers: ?*@import("../agent/mod.zig").Agent.QuestionAnswers = null,
    index: usize = 0,
    /// The environment a program the tool runs is handed; null inherits this
    /// process's.
    env: ?*const std.process.Environ.Map = null,
    /// Where a command whose output is too long for one result keeps the whole
    /// of it; null leaves it uncached.
    cache_dir: ?[]const u8 = null,

    /// The result a call gets when its arguments cannot be used. The tool
    /// writes the message: it is the one that knows what it needed.
    pub fn refuse(self: Context, message: []const u8) !ToolResult {
        return .{ .content = try self.allocator.dupe(u8, message), .is_error = true };
    }

    /// The same, built from a format string, for a refusal that names the
    /// value or the error it is refusing.
    pub fn refuseFmt(self: Context, comptime fmt: []const u8, args: anytype) !ToolResult {
        return .{ .content = try std.fmt.allocPrint(self.allocator, fmt, args), .is_error = true };
    }

    /// The result a call gets when it still carries the `offset` paging
    /// argument that a tool answering with one page no longer takes: the model
    /// has to narrow the call rather than be handed page one again as though it
    /// were the page it asked for.
    pub fn refuseOffset(self: Context, name: []const u8) !ToolResult {
        return self.refuseFmt(
            "Error: {s} has no 'offset' argument. It answers with one page of output; narrow the call instead of asking for a later page.",
            .{name},
        );
    }
};

/// One built-in tool.
pub const Tool = struct {
    /// The name the model calls. `schema.zig` and `dispatch.zig` both take it
    /// from here, so a name cannot be offered without being runnable.
    name: []const u8,
    /// What the model is told the tool does.
    description: []const u8,
    /// The JSON schema of the tool's arguments; parsed before it is put into a
    /// request, never spliced into one.
    parameters_json: []const u8,
    /// What the terminal shows while the tool runs. Null for a tool that must
    /// not have that line — it writes on the terminal itself.
    label: ?[]const u8 = null,
    /// Writes its own terminal announcement, before the usual call preview.
    quiet: bool = false,
    /// Read the call's arguments, validate them, and do what they ask. A call
    /// this function cannot use comes back with `is_error` set rather than as
    /// an error: what the model needs is a sentence telling it what to fix.
    run: *const fn (Context, []const u8) anyerror!ToolResult,
};
