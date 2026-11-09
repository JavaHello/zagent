const std = @import("std");
const tools = @import("tools.zig");
const openai = @import("openai.zig");

pub fn execute(io: std.Io, allocator: std.mem.Allocator, env: *const std.process.Environ.Map, name: []const u8, arguments: []const u8) !tools.ToolResult {
    const search = tools.detectSearchBackends(io, env);
    return blk: {
        if (std.mem.eql(u8, name, "bash") or std.mem.eql(u8, name, "shell")) {
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
        } else if (std.mem.eql(u8, name, "read_file")) {
            const path = openai.extractStringArg(allocator, arguments, "path") catch {
                break :blk .{
                    .content = try allocator.dupe(u8, "Error: missing 'path' argument"),
                    .is_error = true,
                };
            };
            defer allocator.free(path);
            break :blk try tools.readFile(io, allocator, path);
        } else if (std.mem.eql(u8, name, "write_file")) {
            const path = openai.extractStringArg(allocator, arguments, "path") catch {
                break :blk .{
                    .content = try allocator.dupe(u8, "Error: missing 'path' argument"),
                    .is_error = true,
                };
            };
            defer allocator.free(path);
            const content = openai.extractStringArg(allocator, arguments, "content") catch {
                break :blk .{
                    .content = try allocator.dupe(u8, "Error: missing 'content' argument"),
                    .is_error = true,
                };
            };
            defer allocator.free(content);
            break :blk try tools.writeFile(io, allocator, path, content);
        } else if (std.mem.eql(u8, name, "edit_file")) {
            const path = try openai.extractStringArg(allocator, arguments, "path");
            defer allocator.free(path);
            const old_text = try openai.extractStringArg(allocator, arguments, "old_text");
            defer allocator.free(old_text);
            const new_text = try openai.extractStringArg(allocator, arguments, "new_text");
            defer allocator.free(new_text);
            break :blk try tools.editFile(io, allocator, path, old_text, new_text);
        } else if (std.mem.eql(u8, name, "apply_patch")) {
            const patch_text = openai.extractStringArg(allocator, arguments, "patch") catch {
                break :blk .{
                    .content = try allocator.dupe(u8, "Error: missing 'patch' argument; it has to hold a unified diff"),
                    .is_error = true,
                };
            };
            defer allocator.free(patch_text);
            break :blk try tools.applyPatch(io, allocator, patch_text);
        } else if (std.mem.eql(u8, name, "list_dir")) {
            const path = openai.extractStringArg(allocator, arguments, "path") catch {
                break :blk .{
                    .content = try allocator.dupe(u8, "Error: missing 'path' argument"),
                    .is_error = true,
                };
            };
            defer allocator.free(path);
            break :blk try tools.listDir(io, allocator, path);
        } else if (std.mem.eql(u8, name, "grep")) {
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
        } else if (std.mem.eql(u8, name, "find")) {
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
