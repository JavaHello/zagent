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
    answers: ?*@import("ask_user.zig").QuestionAnswers = null,
    index: usize = 0,
    /// The environment a program the tool runs is handed; null inherits this
    /// process's.
    env: ?*const std.process.Environ.Map = null,
    /// Where a command whose output is too long for one result keeps the whole
    /// of it; null leaves it uncached.
    cache_dir: ?[]const u8 = null,
    /// Call-wide middleware, including dynamically discovered MCP tools.
    hooks: Hooks = .{},
    /// Optional caller-owned state for hooks; never retained by dispatch.
    hook_data: ?*anyopaque = null,

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

/// Execution middleware. Before may return an owned result to skip execution.
/// After receives the run's success OR error, and consumes any result content on
/// every path (including when returning an error). It can replace the result,
/// for example by caching its full content and returning a CCR preview.
/// After is not called when before fails or short-circuits.
pub const Hooks = struct {
    before: ?*const fn (Context, []const u8, []const u8) anyerror!?ToolResult = null,
    after: ?*const fn (Context, []const u8, []const u8, anyerror!ToolResult) anyerror!ToolResult = null,

    pub fn beforeExecute(self: Hooks, ctx: Context, name: []const u8, arguments: []const u8) !?ToolResult {
        if (self.before) |callback| return callback(ctx, name, arguments);
        return null;
    }

    pub fn afterExecute(self: Hooks, ctx: Context, name: []const u8, arguments: []const u8, outcome: anyerror!ToolResult) !ToolResult {
        if (self.after) |callback| return callback(ctx, name, arguments, outcome);
        return outcome;
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
    /// Tool-owned argument preview; false leaves the raw arguments visible.
    summary: ?*const fn (Context, *std.Io.Writer, []const u8) anyerror!bool = null,
    /// A block preview may contain trusted rendering, such as a sanitised diff.
    summary_block: bool = false,
    /// Delegated activity gets a distinct glyph and colour in the host UI.
    delegated: bool = false,
    progress: ?*const fn (Context, *std.Io.Writer.Allocating, []const u8) anyerror!?[]const u8 = null,
    /// Read the call's arguments, validate them, and do what they ask. A call
    /// this function cannot use comes back with `is_error` set rather than as
    /// an error: what the model needs is a sentence telling it what to fix.
    run: *const fn (Context, []const u8) anyerror!ToolResult,
    /// Tool-local hooks run inside the caller's Context.hooks.
    hooks: Hooks = .{},

    pub fn beforeExecute(self: Tool, ctx: Context, arguments: []const u8) !?ToolResult {
        return self.hooks.beforeExecute(ctx, self.name, arguments);
    }

    pub fn afterExecute(self: Tool, ctx: Context, arguments: []const u8, outcome: anyerror!ToolResult) !ToolResult {
        return self.hooks.afterExecute(ctx, self.name, arguments, outcome);
    }

    pub fn execute(self: Tool, ctx: Context, arguments: []const u8) !ToolResult {
        if (try self.beforeExecute(ctx, arguments)) |result| return result;
        return self.afterExecute(ctx, arguments, self.run(ctx, arguments));
    }
};

test "local hooks forward context and arguments, short circuit, recover and consume errors" {
    const Harness = struct {
        events: std.ArrayList(u8) = .empty,
        mode: enum { normal, short, before_error, run_error, after_error } = .normal,

        fn state(ctx: Context, name: []const u8, args: []const u8) !*@This() {
            try std.testing.expectEqualStrings("hook_test", name);
            try std.testing.expectEqualStrings("opaque arguments", args);
            try std.testing.expectEqual(@as(usize, 17), ctx.index);
            try std.testing.expectEqualStrings("cache-sentinel", ctx.cache_dir.?);
            return @ptrCast(@alignCast(ctx.hook_data.?));
        }
        fn before(ctx: Context, name: []const u8, args: []const u8) !?ToolResult {
            const self = try state(ctx, name, args);
            try self.events.append(ctx.allocator, 'B');
            if (self.mode == .before_error) return error.BeforeFailed;
            if (self.mode == .short) return try value(ctx, "short");
            return null;
        }
        fn value(ctx: Context, text: []const u8) !ToolResult {
            return .{ .content = try ctx.allocator.dupe(u8, text), .is_error = false };
        }
        fn run(ctx: Context, args: []const u8) !ToolResult {
            const self = try state(ctx, "hook_test", args);
            try self.events.append(ctx.allocator, 'R');
            if (self.mode == .run_error) return error.RunFailed;
            return value(ctx, "run");
        }
        fn after(ctx: Context, name: []const u8, args: []const u8, outcome: anyerror!ToolResult) !ToolResult {
            const self = try state(ctx, name, args);
            try self.events.append(ctx.allocator, 'A');
            const result = outcome catch |err| {
                try std.testing.expectEqual(error.RunFailed, err);
                return value(ctx, "recovered");
            };
            if (self.mode == .after_error) {
                result.deinit(ctx.allocator);
                return error.AfterFailed;
            }
            return result;
        }
    };
    const spec: Tool = .{ .name = "hook_test", .description = "test", .parameters_json = "{}", .run = Harness.run, .hooks = .{ .before = Harness.before, .after = Harness.after } };
    const Case = struct { mode: @FieldType(Harness, "mode"), events: []const u8, text: ?[]const u8 = null, err: ?anyerror = null };
    for ([_]Case{
        .{ .mode = .normal, .events = "BRA", .text = "run" },
        .{ .mode = .short, .events = "B", .text = "short" },
        .{ .mode = .before_error, .events = "B", .err = error.BeforeFailed },
        .{ .mode = .run_error, .events = "BRA", .text = "recovered" },
        .{ .mode = .after_error, .events = "BRA", .err = error.AfterFailed },
    }) |case| {
        var state: Harness = .{ .mode = case.mode };
        defer state.events.deinit(std.testing.allocator);
        const ctx: Context = .{ .io = std.testing.io, .allocator = std.testing.allocator, .index = 17, .cache_dir = "cache-sentinel", .hook_data = &state };
        const outcome = spec.execute(ctx, "opaque arguments");
        if (case.err) |err| {
            try std.testing.expectError(err, outcome);
        } else {
            const result = try outcome;
            defer result.deinit(ctx.allocator);
            try std.testing.expectEqualStrings(case.text.?, result.content);
        }
        try std.testing.expectEqualStrings(case.events, state.events.items);
    }
}
