const std = @import("std");
const tools = @import("../tools/mod.zig");
const openai = @import("../model/openai.zig");

pub fn execute(io: std.Io, allocator: std.mem.Allocator, env: *const std.process.Environ.Map, name: []const u8, arguments: []const u8) !tools.ToolResult {
    if (refusesOffset(name) and carriesOffset(allocator, arguments)) return .{
        .content = try std.fmt.allocPrint(
            allocator,
            "Error: {s} has no 'offset' argument. It answers with one page of output; narrow the call instead of asking for a later page.",
            .{name},
        ),
        .is_error = true,
    };
    return blk: {
        if (std.mem.eql(u8, name, "bash")) {
            const command = openai.extractStringArg(allocator, arguments, "command") catch {
                break :blk .{
                    .content = try allocator.dupe(u8, "Error: missing 'command' argument"),
                    .is_error = true,
                };
            };
            defer allocator.free(command);
            break :blk try tools.executeShellWithEnv(io, allocator, command, env);
        } else if (std.mem.eql(u8, name, "read")) {
            const path = openai.extractStringArg(allocator, arguments, "path") catch {
                break :blk .{
                    .content = try allocator.dupe(u8, "Error: missing 'path' argument"),
                    .is_error = true,
                };
            };
            defer allocator.free(path);
            const range = tools.parseReadPage(allocator, arguments) catch {
                break :blk .{
                    .content = try allocator.dupe(u8, "Error: read takes a path plus an optional 'offset' (1-based first line) and 'limit' (line count), both integers of at least 1"),
                    .is_error = true,
                };
            };
            break :blk try tools.readFilePage(io, allocator, path, range);
        } else if (std.mem.eql(u8, name, "write")) {
            const path = openai.extractStringArg(allocator, arguments, "path") catch {
                break :blk .{
                    .content = try allocator.dupe(u8, "Error: missing 'path' argument"),
                    .is_error = true,
                };
            };
            defer allocator.free(path);
            const parsed = try std.json.parseFromSlice(std.json.Value, allocator, arguments, .{});
            defer parsed.deinit();
            const fields = parsed.value.object;
            if (fields.contains("old_text") or fields.contains("new_text")) {
                break :blk .{
                    .content = try allocator.dupe(u8, "Error: write takes 'path' and 'content'; use edit for 'old_text' and 'new_text'"),
                    .is_error = true,
                };
            }
            const content = openai.extractStringArg(allocator, arguments, "content") catch {
                break :blk .{
                    .content = try allocator.dupe(u8, "Error: missing 'content' argument"),
                    .is_error = true,
                };
            };
            defer allocator.free(content);
            break :blk try tools.writeFile(io, allocator, path, content);
        } else if (std.mem.eql(u8, name, "edit")) {
            const parsed = std.json.parseFromSlice(struct {
                path: []const u8,
                old_text: []const u8,
                new_text: []const u8,
            }, allocator, arguments, .{}) catch {
                break :blk .{
                    .content = try allocator.dupe(u8, "Error: edit requires 'path', 'old_text' and 'new_text' strings; do not pass 'content'"),
                    .is_error = true,
                };
            };
            defer parsed.deinit();
            break :blk try tools.editFile(io, allocator, parsed.value.path, parsed.value.old_text, parsed.value.new_text);
        } else if (std.mem.eql(u8, name, "apply_patch")) {
            const patch_text = openai.extractStringArg(allocator, arguments, "patch") catch {
                break :blk .{
                    .content = try allocator.dupe(u8, "Error: missing 'patch' argument; it has to hold a unified diff"),
                    .is_error = true,
                };
            };
            defer allocator.free(patch_text);
            break :blk try tools.applyPatch(io, allocator, patch_text);
        } else if (std.mem.eql(u8, name, "ls")) {
            const parsed = std.json.parseFromSlice(struct {
                path: []const u8 = ".",
                limit: usize = 100,
            }, allocator, arguments, .{ .ignore_unknown_fields = true }) catch {
                break :blk .{
                    .content = try allocator.dupe(u8, "Error: ls expects an optional 'path' string (defaults to the current directory) and a 'limit' integer"),
                    .is_error = true,
                };
            };
            defer parsed.deinit();
            break :blk try tools.listDirPage(io, allocator, parsed.value.path, .{ .limit = parsed.value.limit });
        } else if (std.mem.eql(u8, name, "rg") or std.mem.eql(u8, name, "grep")) {
            const args = tools.parseGrepArgs(allocator, arguments) catch |err| {
                break :blk .{
                    .content = try std.fmt.allocPrint(
                        allocator,
                        "Error: {s} arguments are unusable ({s}); expected a non-empty pattern, optional path/glob strings, ignore_case boolean, context_lines integer >= 0, and max_matches integer >= 1",
                        .{ name, @errorName(err) },
                    ),
                    .is_error = true,
                };
            };
            defer args.deinit(allocator);
            break :blk if (std.mem.eql(u8, name, "rg"))
                try tools.rg(io, allocator, args)
            else
                try tools.grep(io, allocator, args);
        } else if (std.mem.eql(u8, name, "fd") or std.mem.eql(u8, name, "find")) {
            const args = tools.parseFindArgs(allocator, arguments) catch |err| {
                break :blk .{
                    .content = try std.fmt.allocPrint(
                        allocator,
                        "Error: {s} arguments are unusable ({s}); it needs a non-empty 'pattern' holding a glob, and a 'path' it can use",
                        .{ name, @errorName(err) },
                    ),
                    .is_error = true,
                };
            };
            defer args.deinit(allocator);
            break :blk if (std.mem.eql(u8, name, "fd"))
                try tools.fd(io, allocator, args)
            else
                try tools.find(io, allocator, args);
        } else if (std.mem.eql(u8, name, "http")) {
            const request = tools.parseHttpRequest(allocator, arguments) catch |err| {
                break :blk .{
                    .content = try std.fmt.allocPrint(
                        allocator,
                        "Error: http arguments are unusable ({s}); it needs a 'url', and a 'method', 'headers', 'body', and 'save_to' it can use",
                        .{@errorName(err)},
                    ),
                    .is_error = true,
                };
            };
            defer request.deinit(allocator);
            break :blk try tools.httpRequest(io, allocator, request);
        } else {
            return error.UnknownTool;
        }
    };
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
    const full = try execute(io, a, &env, "read", defaults);
    defer full.deinit(a);
    try std.testing.expect(!full.is_error);
    try std.testing.expectEqualStrings("1:first\n2:second\n3:third\n", full.content);
    const args = try std.json.Stringify.valueAlloc(a, .{ .path = path, .offset = 2, .limit = 1 }, .{});
    defer a.free(args);
    const page = try execute(io, a, &env, "read", args);
    defer page.deinit(a);
    try std.testing.expect(!page.is_error);
    try std.testing.expectEqualStrings("2:second\n[Output truncated; continue with offset=3 (1-based line number).]", page.content);
    const invalid = try std.json.Stringify.valueAlloc(a, .{ .path = path, .offset = 0 }, .{});
    defer a.free(invalid);
    const rejected = try execute(io, a, &env, "read", invalid);
    defer rejected.deinit(a);
    try std.testing.expect(rejected.is_error);
    try std.testing.expect(std.mem.indexOf(u8, rejected.content, "offset") != null);
    // Shared parser for both advertised backend names.
    for ([_][]const u8{ "rg", "grep" }) |name| {
        const invalid_search = try execute(io, a, &env, name, "{\"pattern\":\"x\",\"max_matches\":0}");
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
        const result = try execute(io, a, &env, name, "{\"pattern\":\"x\",\"offset\":2}");
        defer result.deinit(a);
        try std.testing.expect(result.is_error);
        try std.testing.expect(std.mem.indexOf(u8, result.content, "has no 'offset'") != null);
    }
    // The same call without it is dispatched as usual.
    const listed = try execute(io, a, &env, "ls", "{\"limit\":1}");
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
        const result = try execute(io, a, &env, "write", args);
        defer result.deinit(a);
        try std.testing.expect(!result.is_error);
        const actual = try tmp.dir.readFileAlloc(io, "new.txt", a, .limited(1024));
        defer a.free(actual);
        try std.testing.expectEqualStrings(content, actual);
    }
    const mixed = try std.json.Stringify.valueAlloc(a, .{ .path = path, .content = "bad", .old_text = "old", .new_text = "new" }, .{});
    defer a.free(mixed);
    const rejected = try execute(io, a, &env, "write", mixed);
    defer rejected.deinit(a);
    try std.testing.expect(rejected.is_error);
    const unchanged = try tmp.dir.readFileAlloc(io, "new.txt", a, .limited(1024));
    defer a.free(unchanged);
    try std.testing.expectEqualStrings("", unchanged);
    for ([_][]const u8{ "shell", "read_file", "write_file", "edit_file", "list_dir", "http_request" }) |name| {
        try std.testing.expectError(error.UnknownTool, execute(io, a, &env, name, "{}"));
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
        const result = try execute(std.testing.io, a, &env, case.name, case.args);
        defer result.deinit(a);
        try std.testing.expect(result.is_error);
    }
}

test "http dispatches to request argument validation" {
    const a = std.testing.allocator;
    var env = std.process.Environ.Map.init(a);
    defer env.deinit();
    const result = try execute(std.testing.io, a, &env, "http", "{}");
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
    const before = try execute(io, a, &env, "read", args);
    defer before.deinit(a);
    try std.testing.expectEqualStrings("1:before\n", before.content);
    const legacy = try execute(io, a, &env, "write", args);
    defer legacy.deinit(a);
    try std.testing.expect(legacy.is_error);
    const edited = try execute(io, a, &env, "edit", args);
    defer edited.deinit(a);
    try std.testing.expect(!edited.is_error);
    const after = try execute(io, a, &env, "read", args);
    defer after.deinit(a);
    try std.testing.expectEqualStrings("1:after\n", after.content);
    const dir_args = try std.json.Stringify.valueAlloc(a, .{ .path = std.fs.path.dirname(path).? }, .{});
    defer a.free(dir_args);
    const listed = try execute(io, a, &env, "ls", dir_args);
    defer listed.deinit(a);
    try std.testing.expect(!listed.is_error);
    try std.testing.expect(std.mem.indexOf(u8, listed.content, "note.txt") != null);
}

test "ls defaults to the current directory" {
    const a = std.testing.allocator;
    var env = std.process.Environ.Map.init(a);
    defer env.deinit();
    const result = try execute(std.testing.io, a, &env, "ls", "{}");
    defer result.deinit(a);
    try std.testing.expect(!result.is_error);
    const explicit = try execute(std.testing.io, a, &env, "ls", "{\"path\":\".\"}");
    defer explicit.deinit(a);
    try std.testing.expect(!explicit.is_error);
    try std.testing.expectEqualStrings(explicit.content, result.content);
}

test "ls rejects invalid path arguments" {
    const a = std.testing.allocator;
    var env = std.process.Environ.Map.init(a);
    defer env.deinit();
    for ([_][]const u8{ "{\"path\":null}", "{\"path\":42}", "[]", "not json" }) |args| {
        const result = try execute(std.testing.io, a, &env, "ls", args);
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
        const result = try execute(std.testing.io, a, &env, name, "{\"path\":\"/zagent-missing-test-directory/file\"}");
        defer result.deinit(a);
        try std.testing.expect(result.is_error);
    }
    for ([_][]const u8{"edit"}) |name| {
        const result = try execute(std.testing.io, a, &env, name, "{\"path\":\"/zagent-missing-test-directory/file\",\"old_text\":\"old\",\"new_text\":\"new\"}");
        defer result.deinit(a);
        try std.testing.expect(result.is_error);
        try std.testing.expect(std.mem.indexOf(u8, result.content, "Error opening") != null);
    }
    for ([_][]const u8{ "rg", "fd", "grep", "find" }) |name| {
        const result = try execute(std.testing.io, a, &env, name, "{}");
        defer result.deinit(a);
        try std.testing.expect(result.is_error);
    }
}
