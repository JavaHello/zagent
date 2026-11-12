//! One tool call, sent to the tool that answers it.
//!
//! The model names a tool and gives it JSON arguments; this is the only place
//! that turns those into a call. It runs in this process, so there is no
//! protocol here: arguments are read where they are used, and the result is the
//! tool's own. The deadline and the bound on output belong to the tools that
//! run a program (`bash`, the searches), which is where the output is read.
//!
//! A name that is not in this table is a fault in this program rather than
//! something the model can cause: the tools advertised to it are built from the
//! same list.
const std = @import("std");
const tools = @import("mod.zig");
const bash = @import("bash.zig");
const openai = @import("../model/openai.zig");

const ToolResult = tools.ToolResult;

/// Run one built-in tool. `cache_dir` is where a command whose output is too
/// long for one result keeps the whole of it, for `ccr_retrieve` to read back;
/// null leaves it uncached.
pub fn execute(
    io: std.Io,
    allocator: std.mem.Allocator,
    env: ?*const std.process.Environ.Map,
    cache_dir: ?[]const u8,
    name: []const u8,
    arguments: []const u8,
) !ToolResult {
    if (refusesOffset(name) and carriesOffset(allocator, arguments)) return .{
        .content = try std.fmt.allocPrint(
            allocator,
            "Error: {s} has no 'offset' argument. It answers with one page of output; narrow the call instead of asking for a later page.",
            .{name},
        ),
        .is_error = true,
    };

    if (std.mem.eql(u8, name, "bash")) {
        const command = openai.extractStringArg(allocator, arguments, "command") catch
            return refuse(allocator, "Error: missing 'command' argument");
        defer allocator.free(command);
        const timeout_seconds = shellTimeout(allocator, arguments) catch return .{
            .content = try allocator.dupe(u8, "Invalid timeout_seconds: use an integer from 1 to 3600."),
            .is_error = true,
        };
        return bash.executeShellTimed(io, allocator, command, env, cache_dir, timeout_seconds);
    }
    if (std.mem.eql(u8, name, "read")) {
        const path = openai.extractStringArg(allocator, arguments, "path") catch
            return refuse(allocator, "Error: missing 'path' argument");
        defer allocator.free(path);
        const range = tools.parseReadPage(allocator, arguments) catch return .{
            .content = try allocator.dupe(u8, "Error: read takes a path plus an optional 'offset' (1-based first line) and 'limit' (line count), both integers of at least 1"),
            .is_error = true,
        };
        return tools.readFilePage(io, allocator, path, range);
    }
    if (std.mem.eql(u8, name, "write")) {
        const path = openai.extractStringArg(allocator, arguments, "path") catch
            return refuse(allocator, "Error: missing 'path' argument");
        defer allocator.free(path);
        const parsed = try std.json.parseFromSlice(std.json.Value, allocator, arguments, .{});
        defer parsed.deinit();
        const fields = parsed.value.object;
        if (fields.contains("old_text") or fields.contains("new_text")) return .{
            .content = try allocator.dupe(u8, "Error: write takes 'path' and 'content'; use edit for 'old_text' and 'new_text'"),
            .is_error = true,
        };
        const content = openai.extractStringArg(allocator, arguments, "content") catch
            return refuse(allocator, "Error: missing 'content' argument");
        defer allocator.free(content);
        return tools.writeFile(io, allocator, path, content);
    }
    if (std.mem.eql(u8, name, "edit")) {
        const parsed = std.json.parseFromSlice(struct {
            path: []const u8,
            old_text: []const u8,
            new_text: []const u8,
        }, allocator, arguments, .{}) catch return .{
            .content = try allocator.dupe(u8, "Error: edit requires 'path', 'old_text' and 'new_text' strings; do not pass 'content'"),
            .is_error = true,
        };
        defer parsed.deinit();
        return tools.editFile(io, allocator, parsed.value.path, parsed.value.old_text, parsed.value.new_text);
    }
    if (std.mem.eql(u8, name, "apply_patch")) {
        const patch_text = openai.extractStringArg(allocator, arguments, "patch") catch
            return refuse(allocator, "Error: missing 'patch' argument; it has to hold a unified diff");
        defer allocator.free(patch_text);
        return tools.applyPatch(io, allocator, patch_text);
    }
    if (std.mem.eql(u8, name, "ls")) {
        const parsed = std.json.parseFromSlice(struct {
            path: []const u8 = ".",
            limit: usize = 100,
        }, allocator, arguments, .{ .ignore_unknown_fields = true }) catch return .{
            .content = try allocator.dupe(u8, "Error: ls expects an optional 'path' string (defaults to the current directory) and a 'limit' integer"),
            .is_error = true,
        };
        defer parsed.deinit();
        return tools.listDirPage(io, allocator, parsed.value.path, .{ .limit = parsed.value.limit });
    }
    if (std.mem.eql(u8, name, "rg") or std.mem.eql(u8, name, "grep")) {
        const args = tools.parseGrepArgs(allocator, arguments) catch |err| return .{
            .content = try std.fmt.allocPrint(
                allocator,
                "Error: {s} arguments are unusable ({s}); expected a non-empty pattern, optional path/glob strings, ignore_case boolean, context_lines integer >= 0, and max_matches integer >= 1",
                .{ name, @errorName(err) },
            ),
            .is_error = true,
        };
        defer args.deinit(allocator);
        return if (std.mem.eql(u8, name, "rg"))
            tools.rg(io, allocator, args)
        else
            tools.grep(io, allocator, args);
    }
    if (std.mem.eql(u8, name, "fd") or std.mem.eql(u8, name, "find")) {
        const args = tools.parseFindArgs(allocator, arguments) catch |err| return .{
            .content = try std.fmt.allocPrint(
                allocator,
                "Error: {s} arguments are unusable ({s}); it needs a non-empty 'pattern' holding a glob, and a 'path' it can use",
                .{ name, @errorName(err) },
            ),
            .is_error = true,
        };
        defer args.deinit(allocator);
        return if (std.mem.eql(u8, name, "fd"))
            tools.fd(io, allocator, args)
        else
            tools.find(io, allocator, args);
    }
    if (std.mem.eql(u8, name, "http")) {
        const request = tools.parseHttpRequest(allocator, arguments) catch |err| return .{
            .content = try std.fmt.allocPrint(
                allocator,
                "Error: http arguments are unusable ({s}); it needs a 'url', and a 'method', 'headers', 'body', and 'save_to' it can use",
                .{@errorName(err)},
            ),
            .is_error = true,
        };
        defer request.deinit(allocator);
        return tools.httpRequest(io, allocator, request);
    }
    return error.UnknownTool;
}

/// The result a call gets when it left out an argument its tool needs.
fn refuse(allocator: std.mem.Allocator, message: []const u8) !ToolResult {
    return .{ .content = try allocator.dupe(u8, message), .is_error = true };
}

/// The deadline a `bash` call asked for, in seconds. Arguments that do not
/// parse, or a number outside 1..3600, are refused rather than defaulted: a
/// command that runs longer than the caller meant is worse than a failed call.
fn shellTimeout(allocator: std.mem.Allocator, arguments: []const u8) !u32 {
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, arguments, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidArguments;
    const value = parsed.value.object.get("timeout_seconds") orelse return bash.default_timeout_seconds;
    if (value != .integer or value.integer < 1 or value.integer > bash.max_timeout_seconds) return error.InvalidTimeout;
    return @intCast(value.integer);
}

/// The tools that used to page their output with an `offset`. They answer with
/// one page now, so a call that still carries the argument is told that rather
/// than handed page one again as though it were the page it asked for.
fn refusesOffset(name: []const u8) bool {
    for ([_][]const u8{ "ls", "rg", "grep", "fd", "find" }) |tool|
        if (std.mem.eql(u8, name, tool)) return true;
    return false;
}

/// Whether the arguments name an `offset` field. Arguments that do not parse
/// are not this check's business: the tool itself reports them.
fn carriesOffset(allocator: std.mem.Allocator, arguments: []const u8) bool {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, arguments, .{}) catch return false;
    defer parsed.deinit();
    if (parsed.value != .object) return false;
    return parsed.value.object.get("offset") != null;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "read dispatch forwards the page the caller asked for" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var env = std.process.Environ.Map.init(a);
    defer env.deinit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "lines.txt", .data = "first\nsecond\nthird" });
    const path = try tmp.dir.realPathFileAlloc(io, "lines.txt", a);
    defer a.free(path);
    const defaults = try std.json.Stringify.valueAlloc(a, .{ .path = path }, .{});
    defer a.free(defaults);
    const full = try execute(io, a, &env, null, "read", defaults);
    defer full.deinit(a);
    try std.testing.expect(!full.is_error);
    try std.testing.expectEqualStrings("1:first\n2:second\n3:third\n", full.content);
    const args = try std.json.Stringify.valueAlloc(a, .{ .path = path, .offset = 2, .limit = 1 }, .{});
    defer a.free(args);
    const page = try execute(io, a, &env, null, "read", args);
    defer page.deinit(a);
    try std.testing.expect(!page.is_error);
    try std.testing.expectEqualStrings("2:second\n[Output truncated; continue with offset=3 (1-based line number).]", page.content);
    const invalid = try std.json.Stringify.valueAlloc(a, .{ .path = path, .offset = 0 }, .{});
    defer a.free(invalid);
    const rejected = try execute(io, a, &env, null, "read", invalid);
    defer rejected.deinit(a);
    try std.testing.expect(rejected.is_error);
    try std.testing.expect(std.mem.indexOf(u8, rejected.content, "offset") != null);
    // Shared parser for both advertised backend names.
    for ([_][]const u8{ "rg", "grep" }) |name| {
        const invalid_search = try execute(io, a, &env, null, name, "{\"pattern\":\"x\",\"max_matches\":0}");
        defer invalid_search.deinit(a);
        try std.testing.expect(invalid_search.is_error);
        try std.testing.expect(std.mem.indexOf(u8, invalid_search.content, "max_matches") != null);
    }
}

test "ls and the searches refuse the offset paging they no longer take" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var env = std.process.Environ.Map.init(a);
    defer env.deinit();
    for ([_][]const u8{ "ls", "rg", "grep", "fd", "find" }) |name| {
        const result = try execute(io, a, &env, null, name, "{\"pattern\":\"x\",\"offset\":2}");
        defer result.deinit(a);
        try std.testing.expect(result.is_error);
        try std.testing.expect(std.mem.indexOf(u8, result.content, "has no 'offset'") != null);
    }
    // The same call without it is dispatched as usual.
    const listed = try execute(io, a, &env, null, "ls", "{\"limit\":1}");
    defer listed.deinit(a);
    try std.testing.expect(!listed.is_error);
}

test "write creates overwrites and rejects mixed modes; legacy names are removed" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var env = std.process.Environ.Map.init(a);
    defer env.deinit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(dir);
    const path = try std.fs.path.join(a, &.{ dir, "new.txt" });
    defer a.free(path);
    for ([_][]const u8{ "created", "overwritten", "" }) |content| {
        const args = try std.json.Stringify.valueAlloc(a, .{ .path = path, .content = content }, .{});
        defer a.free(args);
        const result = try execute(io, a, &env, null, "write", args);
        defer result.deinit(a);
        try std.testing.expect(!result.is_error);
        const actual = try tmp.dir.readFileAlloc(io, "new.txt", a, .limited(1024));
        defer a.free(actual);
        try std.testing.expectEqualStrings(content, actual);
    }
    const mixed = try std.json.Stringify.valueAlloc(a, .{ .path = path, .content = "bad", .old_text = "old", .new_text = "new" }, .{});
    defer a.free(mixed);
    const rejected = try execute(io, a, &env, null, "write", mixed);
    defer rejected.deinit(a);
    try std.testing.expect(rejected.is_error);
    const unchanged = try tmp.dir.readFileAlloc(io, "new.txt", a, .limited(1024));
    defer a.free(unchanged);
    try std.testing.expectEqualStrings("", unchanged);
    for ([_][]const u8{ "shell", "read_file", "write_file", "edit_file", "list_dir", "http_request" }) |name| {
        try std.testing.expectError(error.UnknownTool, execute(io, a, &env, null, name, "{}"));
    }
}

test "write and edit reject missing or mixed arguments" {
    const a = std.testing.allocator;
    var env = std.process.Environ.Map.init(a);
    defer env.deinit();
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
        const result = try execute(std.testing.io, a, &env, null, case.name, case.args);
        defer result.deinit(a);
        try std.testing.expect(result.is_error);
    }
}

test "http dispatches to request argument validation" {
    const a = std.testing.allocator;
    var env = std.process.Environ.Map.init(a);
    defer env.deinit();
    const result = try execute(std.testing.io, a, &env, null, "http", "{}");
    defer result.deinit(a);
    try std.testing.expect(result.is_error);
    try std.testing.expect(std.mem.startsWith(u8, result.content, "Error: http arguments are unusable"));
}

test "read write and ls operate on an existing file" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var env = std.process.Environ.Map.init(a);
    defer env.deinit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "note.txt", .data = "before\n" });
    const path = try tmp.dir.realPathFileAlloc(io, "note.txt", a);
    defer a.free(path);
    const args = try std.json.Stringify.valueAlloc(a, .{ .path = path, .old_text = "before", .new_text = "after" }, .{});
    defer a.free(args);
    const before = try execute(io, a, &env, null, "read", args);
    defer before.deinit(a);
    try std.testing.expectEqualStrings("1:before\n", before.content);
    const legacy = try execute(io, a, &env, null, "write", args);
    defer legacy.deinit(a);
    try std.testing.expect(legacy.is_error);
    const edited = try execute(io, a, &env, null, "edit", args);
    defer edited.deinit(a);
    try std.testing.expect(!edited.is_error);
    const after = try execute(io, a, &env, null, "read", args);
    defer after.deinit(a);
    try std.testing.expectEqualStrings("1:after\n", after.content);
    const dir_args = try std.json.Stringify.valueAlloc(a, .{ .path = std.fs.path.dirname(path).? }, .{});
    defer a.free(dir_args);
    const listed = try execute(io, a, &env, null, "ls", dir_args);
    defer listed.deinit(a);
    try std.testing.expect(!listed.is_error);
    try std.testing.expect(std.mem.indexOf(u8, listed.content, "note.txt") != null);
}

test "ls defaults to the current directory" {
    const a = std.testing.allocator;
    var env = std.process.Environ.Map.init(a);
    defer env.deinit();
    const result = try execute(std.testing.io, a, &env, null, "ls", "{}");
    defer result.deinit(a);
    try std.testing.expect(!result.is_error);
    const explicit = try execute(std.testing.io, a, &env, null, "ls", "{\"path\":\".\"}");
    defer explicit.deinit(a);
    try std.testing.expect(!explicit.is_error);
    try std.testing.expectEqualStrings(explicit.content, result.content);
}

test "ls rejects invalid path arguments" {
    const a = std.testing.allocator;
    var env = std.process.Environ.Map.init(a);
    defer env.deinit();
    for ([_][]const u8{ "{\"path\":null}", "{\"path\":42}", "[]", "not json" }) |args| {
        const result = try execute(std.testing.io, a, &env, null, "ls", args);
        defer result.deinit(a);
        try std.testing.expect(result.is_error);
        try std.testing.expect(std.mem.startsWith(u8, result.content, "Error: ls expects"));
    }
}

test "filesystem tools dispatch without legacy aliases" {
    const a = std.testing.allocator;
    var env = std.process.Environ.Map.init(a);
    defer env.deinit();
    // An invalid path exercises dispatch without changing the workspace.
    for ([_][]const u8{ "read", "ls" }) |name| {
        const result = try execute(std.testing.io, a, &env, null, name, "{\"path\":\"/zagent-missing-test-directory/file\"}");
        defer result.deinit(a);
        try std.testing.expect(result.is_error);
    }
    for ([_][]const u8{"edit"}) |name| {
        const result = try execute(std.testing.io, a, &env, null, name, "{\"path\":\"/zagent-missing-test-directory/file\",\"old_text\":\"old\",\"new_text\":\"new\"}");
        defer result.deinit(a);
        try std.testing.expect(result.is_error);
        try std.testing.expect(std.mem.indexOf(u8, result.content, "Error opening") != null);
    }
    for ([_][]const u8{ "rg", "fd", "grep", "find" }) |name| {
        const result = try execute(std.testing.io, a, &env, null, name, "{}");
        defer result.deinit(a);
        try std.testing.expect(result.is_error);
    }
}

test "a shell deadline is bounded and defaulted, never guessed" {
    const a = std.testing.allocator;
    try std.testing.expectEqual(@as(u32, 180), try shellTimeout(a, "{}"));
    try std.testing.expectEqual(@as(u32, 600), try shellTimeout(a, "{\"timeout_seconds\":600}"));
    try std.testing.expectError(error.InvalidTimeout, shellTimeout(a, "{\"timeout_seconds\":0}"));
    try std.testing.expectError(error.InvalidTimeout, shellTimeout(a, "{\"timeout_seconds\":3601}"));
    try std.testing.expectError(error.InvalidTimeout, shellTimeout(a, "{\"timeout_seconds\":\"600\"}"));
}

test "a shell call that asks for an impossible deadline is refused" {
    const a = std.testing.allocator;
    var env = std.process.Environ.Map.init(a);
    defer env.deinit();
    const result = try execute(std.testing.io, a, &env, null, "bash", "{\"command\":\"true\",\"timeout_seconds\":0}");
    defer result.deinit(a);
    try std.testing.expect(result.is_error);
    try std.testing.expect(std.mem.startsWith(u8, result.content, "Invalid timeout_seconds"));
}
