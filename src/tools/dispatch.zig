//! One tool call, sent to the tool that answers it.
//!
//! The model names a tool and gives it JSON arguments; this is the only place
//! that turns those into a call. The table below is the whole of the dispatch:
//! a comptime array of the built-in tools' own specs, walked by `inline for`, so
//! every name comparison and every call to a `run` is resolved when this program
//! is built rather than looked up from a table at run time. Each tool parses and
//! validates its own arguments where it lives; this file passes the model's JSON
//! on unread and gives the tool's result back.
//!
//! MCP tools are discovered at runtime and forwarded through the agent's
//! registry. Other names must appear in the same specs used by `schema.zig`.
const std = @import("std");
const tool = @import("tool.zig");
const bash = @import("bash.zig");
const read = @import("read.zig");
const write = @import("write.zig");
const edit = @import("edit.zig");
const apply_patch = @import("apply_patch.zig");
const ls = @import("ls.zig");
const rg = @import("rg.zig");
const grep = @import("grep.zig");
const fd = @import("fd.zig");
const find = @import("find.zig");
const http = @import("http.zig");
const ccr = @import("ccr.zig");

const ToolResult = tool.ToolResult;

/// Every built-in tool, including tools that operate on agent state.
pub const all = [_]tool.Tool{
    bash.spec,
    read.spec,
    write.spec,
    edit.spec,
    apply_patch.spec,
    ls.spec,
    rg.spec,
    grep.spec,
    fd.spec,
    find.spec,
    http.spec,
    ccr.spec,
    @import("memory_search.zig").spec,
    @import("memory_save.zig").spec,
    @import("ask_user.zig").spec,
    @import("announce_task.zig").spec,
    @import("plan.zig").spec,
    @import("subagent.zig").spec,
    @import("subagent_stop.zig").spec,
    @import("report.zig").spec,
    @import("load_mcp_tools.zig").spec,
};

/// Run one built-in tool. `ctx` carries what a tool needs besides its arguments:
/// where a long output may be cached, and the environment a program it starts is
/// handed. The arguments are the model's JSON, unread: the tool parses them.
pub fn execute(ctx: tool.Context, name: []const u8, arguments: []const u8) !ToolResult {
    inline for (all) |spec| {
        if (std.mem.eql(u8, name, spec.name)) return spec.run(ctx, arguments);
    }
    // MCP names are discovered at runtime; all calls still share this entry.
    if (std.mem.startsWith(u8, name, @import("../mcp/mod.zig").tool_prefix)) {
        const agent = ctx.agent orelse return ctx.refuse("Error: this tool requires an agent context.");
        return agent.mcp_registry.call(ctx.allocator, name, arguments);
    }
    return error.UnknownTool;
}

pub fn isQuiet(name: []const u8) bool {
    inline for (all) |spec| {
        if (std.mem.eql(u8, name, spec.name)) return spec.quiet;
    }
    return false;
}

/// The spec of one built-in tool, by name, at comptime. The definition the
/// model is shown and the label the terminal displays are read from the same
/// spec a call is dispatched through, so neither can name a tool that does not
/// run.
pub fn specOf(comptime name: []const u8) tool.Tool {
    inline for (all) |spec| {
        if (comptime std.mem.eql(u8, spec.name, name)) return spec;
    }
    @compileError("no built-in tool named '" ++ name ++ "'");
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

/// Run one call the way the agent does, with this process's environment.
fn call(name: []const u8, arguments: []const u8) !ToolResult {
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    return execute(.{
        .io = std.testing.io,
        .allocator = std.testing.allocator,
        .env = &env,
    }, name, arguments);
}

test "session and MCP tools require an agent context" {
    const a = std.testing.allocator;
    const names = [_][]const u8{
        "memory_search", "memory_save",   "ask_user", "announce_task",  "plan",
        "subagent",      "subagent_stop", "report",   "load_mcp_tools", @import("../mcp/mod.zig").tool_prefix ++ "test",
    };
    for (names) |name| {
        const result = try call(name, "{}");
        defer result.deinit(a);
        try std.testing.expect(result.is_error);
        try std.testing.expectEqualStrings("Error: this tool requires an agent context.", result.content);
    }
    try std.testing.expect(isQuiet("announce_task"));
    try std.testing.expect(!isQuiet("subagent"));
    try std.testing.expect(!isQuiet("unknown"));
}

test "read dispatch forwards the page the caller asked for" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "lines.txt", .data = "first\nsecond\nthird" });
    const path = try tmp.dir.realPathFileAlloc(io, "lines.txt", a);
    defer a.free(path);
    const defaults = try std.json.Stringify.valueAlloc(a, .{ .path = path }, .{});
    defer a.free(defaults);
    const full = try call("read", defaults);
    defer full.deinit(a);
    try std.testing.expect(!full.is_error);
    try std.testing.expectEqualStrings("1:first\n2:second\n3:third\n", full.content);
    const args = try std.json.Stringify.valueAlloc(a, .{ .path = path, .offset = 2, .limit = 1 }, .{});
    defer a.free(args);
    const page = try call("read", args);
    defer page.deinit(a);
    try std.testing.expect(!page.is_error);
    try std.testing.expectEqualStrings("2:second\n[Output truncated; continue with offset=3 (1-based line number).]", page.content);
    const invalid = try std.json.Stringify.valueAlloc(a, .{ .path = path, .offset = 0 }, .{});
    defer a.free(invalid);
    const rejected = try call("read", invalid);
    defer rejected.deinit(a);
    try std.testing.expect(rejected.is_error);
    try std.testing.expect(std.mem.indexOf(u8, rejected.content, "offset") != null);
    // Both advertised backend names reach their own tool.
    for ([_][]const u8{ "rg", "grep" }) |name| {
        const invalid_search = try call(name, "{\"pattern\":\"x\",\"max_matches\":0}");
        defer invalid_search.deinit(a);
        try std.testing.expect(invalid_search.is_error);
        try std.testing.expect(std.mem.indexOf(u8, invalid_search.content, "max_matches") != null);
    }
}

test "ls and the searches refuse the offset paging they no longer take" {
    const a = std.testing.allocator;
    for ([_][]const u8{ "ls", "rg", "grep", "fd", "find" }) |name| {
        const result = try call(name, "{\"pattern\":\"x\",\"offset\":2}");
        defer result.deinit(a);
        try std.testing.expect(result.is_error);
        try std.testing.expect(std.mem.indexOf(u8, result.content, "has no 'offset'") != null);
    }
    // The same call without it is dispatched as usual.
    const listed = try call("ls", "{\"limit\":1}");
    defer listed.deinit(a);
    try std.testing.expect(!listed.is_error);
}

test "write creates overwrites and rejects mixed modes; legacy names are removed" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(dir);
    const path = try std.fs.path.join(a, &.{ dir, "new.txt" });
    defer a.free(path);
    for ([_][]const u8{ "created", "overwritten", "" }) |content| {
        const args = try std.json.Stringify.valueAlloc(a, .{ .path = path, .content = content }, .{});
        defer a.free(args);
        const result = try call("write", args);
        defer result.deinit(a);
        try std.testing.expect(!result.is_error);
        const actual = try tmp.dir.readFileAlloc(io, "new.txt", a, .limited(1024));
        defer a.free(actual);
        try std.testing.expectEqualStrings(content, actual);
    }
    const mixed = try std.json.Stringify.valueAlloc(a, .{ .path = path, .content = "bad", .old_text = "old", .new_text = "new" }, .{});
    defer a.free(mixed);
    const rejected = try call("write", mixed);
    defer rejected.deinit(a);
    try std.testing.expect(rejected.is_error);
    const unchanged = try tmp.dir.readFileAlloc(io, "new.txt", a, .limited(1024));
    defer a.free(unchanged);
    try std.testing.expectEqualStrings("", unchanged);
    for ([_][]const u8{ "shell", "read_file", "write_file", "edit_file", "list_dir", "http_request" }) |name| {
        try std.testing.expectError(error.UnknownTool, call(name, "{}"));
    }
}

test "write and edit reject missing or mixed arguments" {
    const a = std.testing.allocator;
    const cases = [_]struct { name: []const u8, args: []const u8 }{
        .{ .name = "write", .args = "{}" },
        .{ .name = "write", .args = "{\"path\":\"unused\"}" },
        .{ .name = "edit", .args = "{}" },
        .{ .name = "edit", .args = "{\"old_text\":\"old\",\"new_text\":\"new\"}" },
        .{ .name = "edit", .args = "{\"path\":\"unused\",\"new_text\":\"new\"}" },
        .{ .name = "edit", .args = "{\"path\":\"unused\",\"old_text\":\"old\"}" },
        .{ .name = "edit", .args = "{\"path\":\"unused\",\"old_text\":\"old\",\"new_text\":\"new\",\"content\":\"bad\"}" },
    };
    for (cases) |case| {
        const result = try call(case.name, case.args);
        defer result.deinit(a);
        try std.testing.expect(result.is_error);
    }
}

test "http dispatches to request argument validation" {
    const a = std.testing.allocator;
    const result = try call("http", "{}");
    defer result.deinit(a);
    try std.testing.expect(result.is_error);
    try std.testing.expect(std.mem.startsWith(u8, result.content, "Error: http arguments are unusable"));
}

test "read write and ls operate on an existing file" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "note.txt", .data = "before\n" });
    const path = try tmp.dir.realPathFileAlloc(io, "note.txt", a);
    defer a.free(path);
    const args = try std.json.Stringify.valueAlloc(a, .{ .path = path, .old_text = "before", .new_text = "after" }, .{});
    defer a.free(args);
    const before = try call("read", args);
    defer before.deinit(a);
    try std.testing.expectEqualStrings("1:before\n", before.content);
    const legacy = try call("write", args);
    defer legacy.deinit(a);
    try std.testing.expect(legacy.is_error);
    const edited = try call("edit", args);
    defer edited.deinit(a);
    try std.testing.expect(!edited.is_error);
    const after = try call("read", args);
    defer after.deinit(a);
    try std.testing.expectEqualStrings("1:after\n", after.content);
    const dir_args = try std.json.Stringify.valueAlloc(a, .{ .path = std.fs.path.dirname(path).? }, .{});
    defer a.free(dir_args);
    const listed = try call("ls", dir_args);
    defer listed.deinit(a);
    try std.testing.expect(!listed.is_error);
    try std.testing.expect(std.mem.indexOf(u8, listed.content, "note.txt") != null);
}

test "ls defaults to the current directory" {
    const a = std.testing.allocator;
    const result = try call("ls", "{}");
    defer result.deinit(a);
    try std.testing.expect(!result.is_error);
    const explicit = try call("ls", "{\"path\":\".\"}");
    defer explicit.deinit(a);
    try std.testing.expect(!explicit.is_error);
    try std.testing.expectEqualStrings(explicit.content, result.content);
}

test "ls rejects invalid path arguments" {
    const a = std.testing.allocator;
    for ([_][]const u8{ "{\"path\":null}", "{\"path\":42}", "{\"limit\":0}", "{\"limit\":1001}", "[]", "not json" }) |args| {
        const result = try call("ls", args);
        defer result.deinit(a);
        try std.testing.expect(result.is_error);
        try std.testing.expect(std.mem.startsWith(u8, result.content, "Error: ls expects"));
    }
}

test "filesystem tools dispatch without legacy aliases" {
    const a = std.testing.allocator;
    // An invalid path exercises dispatch without changing the workspace.
    for ([_][]const u8{ "read", "ls" }) |name| {
        const result = try call(name, "{\"path\":\"/zagent-missing-test-directory/file\"}");
        defer result.deinit(a);
        try std.testing.expect(result.is_error);
    }
    for ([_][]const u8{"edit"}) |name| {
        const result = try call(name, "{\"path\":\"/zagent-missing-test-directory/file\",\"old_text\":\"old\",\"new_text\":\"new\"}");
        defer result.deinit(a);
        try std.testing.expect(result.is_error);
        try std.testing.expect(std.mem.indexOf(u8, result.content, "Error opening") != null);
    }
    for ([_][]const u8{ "rg", "fd", "grep", "find" }) |name| {
        const result = try call(name, "{}");
        defer result.deinit(a);
        try std.testing.expect(result.is_error);
    }
}

test "a shell call that asks for an impossible deadline is refused" {
    const a = std.testing.allocator;
    const result = try call("bash", "{\"command\":\"true\",\"timeout_seconds\":0}");
    defer result.deinit(a);
    try std.testing.expect(result.is_error);
    try std.testing.expect(std.mem.startsWith(u8, result.content, "Invalid timeout_seconds"));
}
