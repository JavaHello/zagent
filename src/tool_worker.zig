const std = @import("std");
const tools = @import("tools.zig");
const openai = @import("openai.zig");

pub fn execute(io: std.Io, allocator: std.mem.Allocator, env: *const std.process.Environ.Map, name: []const u8, arguments: []const u8) !tools.ToolResult {
    const search = tools.detectSearchBackends(io, env);
    return blk: {
        if (std.mem.eql(u8, name, "bash")) {
            const command = openai.extractStringArg(allocator, arguments, "command") catch {
                break :blk .{
                    .content = try allocator.dupe(u8, "Error: missing 'command' argument"),
                    .is_error = true,
                };
            };
            defer allocator.free(command);
            var shell_env = try env.clone(allocator);
            defer shell_env.deinit();
            // Persist compilation caches even when an older controller is still
            // running through an atomically upgraded worker binary.
            try shell_env.put("ZIG_GLOBAL_CACHE_DIR", ".zig-cache/global");
            break :blk try tools.executeShellWithEnv(io, allocator, command, &shell_env);
        } else if (std.mem.eql(u8, name, "read")) {
            const path = openai.extractStringArg(allocator, arguments, "path") catch {
                break :blk .{
                    .content = try allocator.dupe(u8, "Error: missing 'path' argument"),
                    .is_error = true,
                };
            };
            defer allocator.free(path);
            break :blk try tools.readFile(io, allocator, path);
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
            if (!fields.contains("content")) {
                const old_text = try openai.extractStringArg(allocator, arguments, "old_text");
                defer allocator.free(old_text);
                const new_text = try openai.extractStringArg(allocator, arguments, "new_text");
                defer allocator.free(new_text);
                break :blk try tools.editFile(io, allocator, path, old_text, new_text);
            }
            if (fields.contains("old_text") or fields.contains("new_text")) {
                break :blk .{
                    .content = try allocator.dupe(u8, "Error: use either 'content' or 'old_text' and 'new_text', not both"),
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
            const path = openai.extractStringArg(allocator, arguments, "path") catch {
                break :blk .{
                    .content = try allocator.dupe(u8, "Error: missing 'path' argument"),
                    .is_error = true,
                };
            };
            defer allocator.free(path);
            break :blk try tools.listDir(io, allocator, path);
        } else if (std.mem.eql(u8, name, "rg") or std.mem.eql(u8, name, "grep")) {
            const args = tools.parseGrepArgs(allocator, arguments) catch |err| {
                break :blk .{
                    .content = try std.fmt.allocPrint(
                        allocator,
                        "Error: grep arguments are unusable ({s}); it needs a non-empty 'pattern' holding a regular expression, and a 'path', 'glob', and 'ignore_case' it can use",
                        .{@errorName(err)},
                    ),
                    .is_error = true,
                };
            };
            defer args.deinit(allocator);
            break :blk try tools.grep(io, allocator, search, args);
        } else if (std.mem.eql(u8, name, "fd") or std.mem.eql(u8, name, "find")) {
            const args = tools.parseFindArgs(allocator, arguments) catch |err| {
                break :blk .{
                    .content = try std.fmt.allocPrint(
                        allocator,
                        "Error: find arguments are unusable ({s}); it needs a non-empty 'pattern' holding a glob, and a 'path' it can use",
                        .{@errorName(err)},
                    ),
                    .is_error = true,
                };
            };
            defer args.deinit(allocator);
            break :blk try tools.find(io, allocator, search, args);
        } else if (std.mem.eql(u8, name, "http_request")) {
            const request = tools.parseHttpRequest(allocator, arguments) catch |err| {
                break :blk .{
                    .content = try std.fmt.allocPrint(
                        allocator,
                        "Error: http_request arguments are unusable ({s}); it needs a 'url', and a 'method', 'headers', 'body', and 'save_to' it can use",
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
    for ([_][]const u8{ "shell", "read_file", "write_file", "edit_file", "list_dir" }) |name| {
        try std.testing.expectError(error.UnknownTool, execute(io, a, &env, name, "{}"));
    }
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
    try std.testing.expectEqualStrings("before\n", before.content);
    const edited = try execute(io, a, &env, "write", args);
    defer edited.deinit(a);
    try std.testing.expect(!edited.is_error);
    const after = try execute(io, a, &env, "read", args);
    defer after.deinit(a);
    try std.testing.expectEqualStrings("after\n", after.content);
    const dir_args = try std.json.Stringify.valueAlloc(a, .{ .path = std.fs.path.dirname(path).? }, .{});
    defer a.free(dir_args);
    const listed = try execute(io, a, &env, "ls", dir_args);
    defer listed.deinit(a);
    try std.testing.expect(!listed.is_error);
    try std.testing.expect(std.mem.indexOf(u8, listed.content, "note.txt") != null);
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
    for ([_][]const u8{"write"}) |name| {
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
